#!/usr/bin/env python3

import base64
from email import message_from_bytes
import email.utils
import imaplib
import os
import re
import socket
import ssl
import time

# --- KONFIGURACE O365 (Zdroj) ---
O365_SERVER = "outlook.office365.com"
O365_PORT = 993
O365_USERNAME = "milan.kerslager@pslib.cz"
O365_TOKEN_FILE = "o365_access_token"

# --- KONFIGURACE GMAIL (Cíl) ---
GMAIL_SERVER = "imap.gmail.com"
GMAIL_PORT = 993
GMAIL_USERNAME = "milan.kerslager@gmail.com"
GMAIL_TOKEN_FILE = "gmail_access_token"

# Kandidáti na název archivní složky v O365
TARGET_FOLDER_CANDIDATES = ["Archive", "Archiv", "INBOX/Archive", "INBOX/Archiv"]

# Nastavení opakování při chybách
MAX_RETRIES = 3
RETRY_DELAY = 5  # sekundy
SOCKET_TIMEOUT = 30  # timeout pro síťové operace
# --------------------------------


def read_access_token(file_path):
    """Načte access token z textového souboru."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Soubor s tokenem '{file_path}' neexistuje.")

    with open(file_path, "r", encoding="utf-8") as f:
        token = f.read().strip()

    if not token:
        raise ValueError(f"Soubor '{file_path}' je prázdný.")

    return token


def generate_oauth2_string(username, access_token):
    """Vygeneruje SASL XOAUTH2 řetězec v Base64."""
    auth_string = f"user={username}\x01auth=Bearer {access_token}\x01\x01"
    return base64.b64encode(auth_string.encode("utf-8")).decode("ascii")


def connect_imap_oauth2(server, port, username, token_file):
    """Připojí se k IMAP serveru pomocí OAuth2."""
    access_token = read_access_token(token_file)
    context = ssl.create_default_context()

    socket.setdefaulttimeout(SOCKET_TIMEOUT)

    mail = imaplib.IMAP4_SSL(server, port, ssl_context=context)
    b64_auth_str = generate_oauth2_string(username, access_token)

    typ, dat = mail._simple_command("AUTHENTICATE", "XOAUTH2", b64_auth_str)

    if typ != "OK":
        raise imaplib.IMAP4.error(
            f"OAuth2 autentizace pro {server} selhala: {typ} {dat}"
        )

    mail.state = "AUTH"
    return mail


class IMAPConnectionManager:
    """Správce relace, který automaticky obnovuje padlé IMAP spojení."""

    def __init__(self, server, port, username, token_file, default_folder=None):
        self.server = server
        self.port = port
        self.username = username
        self.token_file = token_file
        self.default_folder = default_folder
        self.mail = None
        self.reconnect()

    def reconnect(self):
        """Ukončí případné staré spojení a zřídí nové."""
        if self.mail:
            try:
                self.mail.logout()
            except Exception:
                pass

        print(f"Obnovuji IMAP spojení s {self.server}...")
        self.mail = connect_imap_oauth2(
            self.server, self.port, self.username, self.token_file
        )
        if self.default_folder:
            self.mail.select(self.default_folder)

    def execute_with_retry(
        self, action_fn, description, max_retries=MAX_RETRIES, delay=RETRY_DELAY
    ):
        """Vykoná operaci `action_fn` s opakovaním při selhání sítě."""
        for attempt in range(1, max_retries + 1):
            try:
                return action_fn(self.mail)
            except (
                socket.error,
                socket.timeout,
                ssl.SSLError,
                imaplib.IMAP4.error,
                imaplib.IMAP4.abort,
                OSError,
            ) as e:
                print(
                    f"  [Varování] Pokus {attempt}/{max_retries} selhal ({description}): {e}"
                )
                if attempt < max_retries:
                    time.sleep(delay * attempt)
                    try:
                        self.reconnect()
                    except Exception as rec_err:
                        print(f"  [Chyba reconnectu]: {rec_err}")
                else:
                    print(
                        f"  [Chyba] Všechny pokusy pro '{description}' selhaly."
                    )
                    raise

    def close(self):
        if self.mail:
            try:
                self.mail.close()
                self.mail.logout()
            except Exception:
                pass


def detect_or_create_archive_folder(o365_mgr, candidates):
    """Zjistí název existující archivní složky na O365 nebo ji vytvoří."""

    def _detect(mail):
        status, mailboxes = mail.list()
        existing_folders = []

        if status == "OK" and mailboxes:
            for box in mailboxes:
                decoded = box.decode("utf-8", errors="ignore")
                # Získání názvu složky bez ohledu na separátor
                match = re.search(r'\(.*?\)\s+"?."?\s+"?([^"]+)"?$', decoded)
                if match:
                    existing_folders.append(match.group(1))
                else:
                    existing_folders.append(decoded.split()[-1].strip('"'))

        for candidate in candidates:
            if candidate in existing_folders:
                return candidate

        target = "Archive"
        mail.create(f'"{target}"')
        return target

    folder = o365_mgr.execute_with_retry(_detect, "Detekce archivní složky")
    print(f"Cílová archivní složka na O365: '{folder}'")
    return folder


def extract_internal_date(raw_email):
    """Vytáhne datum z hlavičky e-mailu a převede ho do formátu pro IMAP INTERNALDATE."""
    try:
        msg = message_from_bytes(raw_email)
        date_header = msg.get("Date")

        if date_header:
            parsed_tuple = email.utils.parsedate_tz(date_header)
            if parsed_tuple:
                timestamp = email.utils.mktime_tz(parsed_tuple)
                return imaplib.Time2Internaldate(time.localtime(timestamp))
    except Exception as e:
        print(f"  [Varování] Nepodařilo se přečíst datum zprávy: {e}")

    return None


def parse_append_uid(response_data):
    """Vytáhne nově přidělené UID z IMAP odpovědi po příkazu APPEND."""
    try:
        if response_data and response_data[0]:
            match = re.search(r"APPENDUID\s+\d+\s+(\d+)", response_data[0].decode("utf-8"))
            if match:
                return match.group(1)
    except Exception:
        pass
    return None


def main():
    try:
        o365_mgr = IMAPConnectionManager(
            O365_SERVER,
            O365_PORT,
            O365_USERNAME,
            O365_TOKEN_FILE,
            default_folder='"INBOX"',
        )
        print(f"Úspěšně přihlášeno k O365 ({O365_USERNAME}).")
    except Exception as e:
        print(f"Chyba při přihlašování k O365: {e}")
        return

    try:
        gmail_mgr = IMAPConnectionManager(
            GMAIL_SERVER,
            GMAIL_PORT,
            GMAIL_USERNAME,
            GMAIL_TOKEN_FILE,
            default_folder='"INBOX"',
        )
        print("Úspěšně přihlášeno ke Gmailu (Cíl).")
    except Exception as e:
        print(f"Chyba při přihlašování ke Gmailu: {e}")
        o365_mgr.close()
        return

    dest_folder_o365 = detect_or_create_archive_folder(
        o365_mgr, TARGET_FOLDER_CANDIDATES
    )

    def _search_uids(mail):
        status, data = mail.uid("search", None, "ALL")
        if status != "OK" or not data[0]:
            return []
        return data[0].split()

    uid_list = o365_mgr.execute_with_retry(
        _search_uids, "Načítání seznamu zpráv z O365 INBOXu"
    )

    if not uid_list:
        print("INBOX na O365 je prázdný.")
        o365_mgr.close()
        gmail_mgr.close()
        return

    total_messages = len(uid_list)
    print(f"Nalezeno celkem {total_messages} zpráv k zpracování.")

    def _check_move(mail):
        return "MOVE" in mail.capabilities

    has_move_capability = o365_mgr.execute_with_retry(
        _check_move, "Kontrola IMAP capabilities"
    )

    for idx, uid in enumerate(uid_list, start=1):
        uid_str = uid.decode("ascii")
        print(f"[{idx}/{total_messages}] Zpracovávám zprávu UID {uid_str}...")

        # 1. Stažení zprávy z O365
        def _fetch(mail):
            res, msg_data = mail.uid("fetch", uid, "(RFC822)")
            if res != "OK" or not msg_data or not msg_data[0]:
                raise imaplib.IMAP4.error("Chyba při načítání RFC822 dat.")
            return msg_data[0][1]

        try:
            raw_email = o365_mgr.execute_with_retry(
                _fetch, f"Stahování UID {uid_str}"
            )
        except Exception:
            print(f"Přeskakuji UID {uid_str} z důvodu neúspěšného stažení.")
            continue

        msg_date = extract_internal_date(raw_email)

        # 2. Zápis zprávy do Gmail INBOXu
        def _append(mail):
            res, data = mail.append('"INBOX"', None, msg_date, raw_email)
            if res != "OK":
                raise imaplib.IMAP4.error("Chyba při APPEND do Gmail INBOXu.")

            # Pokus o přesné získání UID z odpovědi APPENDUID
            assigned_uid = parse_append_uid(data)
            if assigned_uid:
                mail.uid("STORE", assigned_uid, "+X-GM-LABELS", r"(\Important)")
            else:
                # Fallback pouze pokud server nevrátil APPENDUID
                mail.select('"INBOX"')
                status, search_data = mail.uid("search", None, "ALL")
                if status == "OK" and search_data[0]:
                    latest_uid = search_data[0].split()[-1]
                    mail.uid("STORE", latest_uid, "+X-GM-LABELS", r"(\Important)")

            return True

        try:
            gmail_mgr.execute_with_retry(
                _append, f"Nahrávání UID {uid_str} do Gmailu"
            )
        except Exception:
            print(
                f"Nepodařilo se nahrát UID {uid_str} do Gmailu. Zpráva zůstává v O365 INBOXu."
            )
            continue

        # 3. Přesun zprávy do Archivu v O365 po úspěšném nahrání
        def _move_or_copy(mail):
            if has_move_capability:
                res, _ = mail.uid("MOVE", uid_str, f'"{dest_folder_o365}"')
                if res != "OK":
                    raise imaplib.IMAP4.error("Chyba při příkazu MOVE.")
            else:
                res, _ = mail.uid("COPY", uid_str, f'"{dest_folder_o365}"')
                if res == "OK":
                    mail.uid("STORE", uid_str, "+FLAGS", "(\\Deleted)")
                else:
                    raise imaplib.IMAP4.error("Chyba při příkazu COPY.")

        try:
            o365_mgr.execute_with_retry(
                _move_or_copy, f"Přesun UID {uid_str} do archivu O365"
            )
        except Exception as e:
            print(
                f"Varování: Zpráva UID {uid_str} byla zkopírována na Gmail, ale neprošel přesun v O365: {e}"
            )

    # Trvalé smazání v O365, pokud se používal COPY fallback
    if not has_move_capability:
        print("Provádím expunge na O365...")

        def _expunge(mail):
            mail.expunge()

        try:
            o365_mgr.execute_with_retry(_expunge, "Expunge v O365")
        except Exception as e:
            print(f"Chyba při expunge: {e}")

    print("Zpracování dokončeno.")
    o365_mgr.close()
    gmail_mgr.close()


if __name__ == "__main__":
    main()
