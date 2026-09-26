// VV Ticket-Dienst — Schlüsselbund (Docker-Secret, nur in diesem Container eingebunden; ADR-11 sops/age).
// Format (scripts/rotate_ticket_key.sh): {"version":1,"active":"<kid>","keys":{"<kid>":"<base64, ≥32 Byte>"}}
// Wird bei Änderung der Datei (mtime/Größe) und auf SIGHUP neu geladen — Schlüsselwechsel ohne Zustand.
import { closeSync, fstatSync, openSync, readFileSync } from "node:fs";

export interface ActiveKey { kid: string; key: Buffer }

export function parseKeyring(text: string): ActiveKey {
  const ring = JSON.parse(text) as { active?: unknown; keys?: Record<string, unknown> };
  const kid = typeof ring.active === "string" ? ring.active : "";
  if (!/^[a-z0-9]{1,16}$/.test(kid)) throw new Error("Keyring: ungültige aktive Kennung");
  const raw = ring.keys?.[kid];
  if (typeof raw !== "string") throw new Error("Keyring: aktiver Schlüssel fehlt");
  const key = Buffer.from(raw, "base64");
  if (key.length < 32 || key.length > 64) throw new Error("Keyring: Schlüssellänge 32–64 Byte verlangt");
  return { kid, key };
}

export class KeyringFile {
  private cached: ActiveKey | null = null;
  private stamp = "";
  constructor(private readonly path: string) {}

  /** Aktueller Signaturschlüssel; wirft (fail-closed), wenn die Datei fehlt/ungültig ist. */
  // Prüfen und Lesen über DENSELBEN Datei-Deskriptor: kein Zeitfenster zwischen stat und read, in dem die
  // Datei (z. B. beim Schlüsselwechsel) ausgetauscht werden könnte (CodeQL js/file-system-race).
  current(): ActiveKey {
    const fd = openSync(this.path, "r");
    try {
      const st = fstatSync(fd);
      const stamp = `${st.mtimeMs}:${st.size}:${st.ino}`;
      if (!this.cached || stamp !== this.stamp) {
        this.cached = parseKeyring(readFileSync(fd, "utf8"));
        this.stamp = stamp;
      }
      return this.cached;
    } finally {
      closeSync(fd);
    }
  }

  reload(): void { this.stamp = ""; }
}
