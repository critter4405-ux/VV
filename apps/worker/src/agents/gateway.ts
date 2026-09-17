// VV Agenten — Pseudonymisierungs-Gateway (ADR-07, K09), WP4-gehärtet.
// Review-Befund Codex #8 / Gemini D: wiederverwendete /g-RegExp (stateful lastIndex) ließ
// beim zweiten Aufruf PII durch; Guard war zu naiv. Jetzt: pro Aufruf frische RegExp,
// erweiterte Muster; Klartext-Mapping bleibt lokal. HEURISTIK + Defense-in-Depth — die
// eigentliche Garantie ist Datenminimierung/Allowlist beim echten Agenten-Bau (kein Klartext raus).

export interface Pseudonymized {
  text: string;
  map: Record<string, string>;   // token -> Klartext (bleibt lokal, geht NIE ans Modell)
}

// Factory: bei JEDEM Aufruf frische RegExp-Objekte (kein geteilter lastIndex-Zustand).
function patterns(): RegExp[] {
  return [
    /[\w.+-]+@[\w-]+\.[\w.-]+/g,                         // E-Mail
    /\bAT\d{2}\s?(?:\d{4}\s?){4}\d{0,2}\b/g,             // IBAN (AT), mit/ohne Leerzeichen
    /\b\d{1,2}\.\d{1,2}\.\d{2,4}\b/g,                    // Datum (Geburtsdatum-Verdacht)
    /\b\d{4}\s?\d{6}\b/g,                                // AT-SVNR (10-stellig)
    /\+?\d[\d\s/()-]{6,}\d/g,                            // Telefonnummer (grob)
  ];
}

export function pseudonymize(input: string): Pseudonymized {
  const map: Record<string, string> = {};
  let text = input;
  let i = 0;
  for (const re of patterns()) {
    text = text.replace(re, (match) => {
      const token = `[[TOK_${i++}]]`;
      map[token] = match;
      return token;
    });
  }
  return { text, map };
}

export function rehydrate(output: string, map: Record<string, string>): string {
  let text = output;
  for (const [token, clear] of Object.entries(map)) text = text.split(token).join(clear);
  return text;
}

// Guard: was rausgeht, enthält keine bekannten PII-Muster mehr. Frische RegExp -> deterministisch.
export function assertNoPii(outbound: string): void {
  for (const re of patterns()) {
    if (re.test(outbound)) {
      throw new Error("Gateway-Guard: potenzieller Personenbezug im Outbound — blockiert (ADR-07)");
    }
  }
}
