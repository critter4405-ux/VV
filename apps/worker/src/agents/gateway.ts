// VV Agenten — Pseudonymisierungs-Gateway (ADR-07, K09).
// Agenten rufen das Modell NIE direkt. Personenbezug wird durch Tokens ersetzt;
// nur Minimiertes geht raus, der Rückweg re-hydriert. Kein Klartext-Personenbezug ans Modell.
// Stage-0: Struktur + Guard; echte Modell-Anbindung folgt beim Agenten-Bau.

export interface Pseudonymized {
  text: string;
  map: Record<string, string>; // token -> Klartext (bleibt lokal, geht NIE raus)
}

const PII_PATTERNS: RegExp[] = [
  /[\w.+-]+@[\w-]+\.[\w.-]+/g,          // E-Mail
  /\b\d{1,2}\.\d{1,2}\.\d{2,4}\b/g,     // Datum (Geburtsdatum-Verdacht)
  /\bAT\d{2}[ ]?(\d{4}[ ]?){4}\d{0,2}\b/g, // IBAN (AT)
];

export function pseudonymize(input: string): Pseudonymized {
  const map: Record<string, string> = {};
  let text = input;
  let i = 0;
  for (const re of PII_PATTERNS) {
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
  for (const [token, clear] of Object.entries(map)) {
    text = text.split(token).join(clear);
  }
  return text;
}

// Guard: was das Gateway rausgibt, enthält keine bekannten PII-Muster mehr.
export function assertNoPii(outbound: string): void {
  for (const re of PII_PATTERNS) {
    if (re.test(outbound)) {
      throw new Error("Gateway-Guard: potenzieller Personenbezug im Outbound — blockiert (ADR-07)");
    }
  }
}
