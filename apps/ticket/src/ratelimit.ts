// VV Ticket-Dienst — einfacher Token-Bucket je Schlüssel (Quelle / Nutzer), im Speicher (zustandslos genug:
// ein Neustart setzt nur die Zähler zurück). Begrenzt Missbrauch einer übernommenen App (Massen-Tickets).
export class RateLimiter {
  private buckets = new Map<string, { tokens: number; at: number }>();
  constructor(private readonly perMinute: number, private readonly burst: number, private readonly maxKeys = 50_000) {}

  take(key: string, nowMs = Date.now()): boolean {
    let b = this.buckets.get(key);
    if (!b) {
      if (this.buckets.size >= this.maxKeys) this.buckets.clear();   // Speicherschutz (fail-safe: neu zählen)
      b = { tokens: this.burst, at: nowMs };
      this.buckets.set(key, b);
    }
    b.tokens = Math.min(this.burst, b.tokens + ((nowMs - b.at) / 60_000) * this.perMinute);
    b.at = nowMs;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }
}
