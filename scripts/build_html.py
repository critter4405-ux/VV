#!/usr/bin/env python3
"""VV Doku-Pipeline — Markdown → farbige, eigenständige HTML mit inline-Mermaid.

    python3 scripts/build_html.py QUELLE.md ZIEL.html "Doktitel" "Badge" "Fußzeile"

- Rendert Markdown (Tabellen, Fenced-Code, Überschriften-Anker).
- ```mermaid-Blöcke werden zu <div class="mermaid"> und inline gerendert
  (mermaid.min.js wird eingebettet → HTML ist offline/AT-souverän, kein CDN).
- Baut eine Navigations-Spalte aus den H2-Überschriften.

Braucht: python-markdown (`pip install markdown`) + scripts/mermaid.min.js daneben.
"""
from __future__ import annotations
import html
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def slugify(text: str) -> str:
    s = re.sub(r"[^\w\s-]", "", text.lower())
    return re.sub(r"[\s]+", "-", s).strip("-")


def extract_mermaid(md: str) -> tuple[str, list[str]]:
    """Ersetzt ```mermaid-Blöcke durch Platzhalter, gibt die Diagramme zurück."""
    blocks: list[str] = []

    def repl(m: re.Match) -> str:
        blocks.append(m.group(1))
        return f"\n@@MERMAID_{len(blocks) - 1}@@\n"

    md = re.sub(r"```mermaid\s*\n(.*?)```", repl, md, flags=re.DOTALL)
    return md, blocks


def build(src: Path, dst: Path, title: str, badge: str, footer: str) -> None:
    try:
        import markdown  # type: ignore
    except ImportError:
        sys.exit("Fehlt: python-markdown. Installiere mit: pip install markdown")

    raw = src.read_text(encoding="utf-8")
    raw, mermaids = extract_mermaid(raw)

    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists"])
    body = md.convert(raw)

    # Mermaid-Platzhalter wieder einsetzen (roher Diagramm-Text, HTML-escaped).
    for i, code in enumerate(mermaids):
        body = body.replace(
            f"<p>@@MERMAID_{i}@@</p>",
            f'<div class="mermaid">{html.escape(code)}</div>',
        )

    # Navigation aus H2.
    nav_items = [
        f'<a href="#{slugify(h)}">{html.escape(h)}</a>'
        for h in re.findall(r"^##\s+(.*)$", raw, re.MULTILINE)
    ]
    # H2 im Body Anker geben.
    body = re.sub(
        r"<h2>(.*?)</h2>",
        lambda m: f'<h2 id="{slugify(re.sub("<.*?>", "", m.group(1)))}">{m.group(1)}</h2>',
        body,
    )

    mermaid_js = (HERE / "mermaid.min.js").read_text(encoding="utf-8")

    doc = f"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
  :root {{ --bg:#0f1b2d; --panel:#16233a; --ink:#eaf0f7; --muted:#9fb2cc;
           --accent:#3fa7ff; --accent2:#4ad6a0; --line:#283a57; --warn:#ffcf6b; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--ink);
          font:16px/1.65 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; }}
  header {{ padding:22px 28px; background:linear-gradient(90deg,#12233d,#0f1b2d);
            border-bottom:2px solid var(--accent); display:flex; align-items:center; gap:16px; }}
  header h1 {{ font-size:20px; margin:0; }}
  .badge {{ background:var(--accent2); color:#04121a; font-weight:700; font-size:12px;
            padding:4px 10px; border-radius:999px; }}
  .wrap {{ display:grid; grid-template-columns:260px 1fr; gap:0; }}
  nav {{ position:sticky; top:0; align-self:start; padding:20px 16px; border-right:1px solid var(--line);
         max-height:100vh; overflow:auto; }}
  nav a {{ display:block; color:var(--muted); text-decoration:none; padding:5px 8px;
           border-radius:8px; font-size:14px; }}
  nav a:hover {{ background:var(--panel); color:var(--ink); }}
  main {{ padding:26px 34px; max-width:960px; }}
  h2 {{ margin-top:2em; padding-bottom:6px; border-bottom:1px solid var(--line); color:var(--accent); }}
  h3 {{ color:var(--accent2); }}
  a {{ color:var(--accent); }}
  code {{ background:#0b1524; padding:2px 6px; border-radius:6px; font-size:.9em; }}
  pre {{ background:#0b1524; padding:14px; border-radius:10px; overflow:auto; border:1px solid var(--line); }}
  table {{ border-collapse:collapse; width:100%; margin:1em 0; }}
  th,td {{ border:1px solid var(--line); padding:8px 10px; text-align:left; vertical-align:top; }}
  th {{ background:var(--panel); }}
  blockquote {{ border-left:3px solid var(--accent2); margin:1em 0; padding:2px 16px;
                background:var(--panel); border-radius:0 8px 8px 0; color:var(--muted); }}
  .mermaid {{ background:#f7fafc; border-radius:12px; padding:16px; margin:1.2em 0; }}
  footer {{ padding:18px 34px; color:var(--muted); border-top:1px solid var(--line); font-size:13px; }}
  @media (max-width:820px) {{ .wrap {{ grid-template-columns:1fr; }} nav {{ position:static; max-height:none; border-right:none; border-bottom:1px solid var(--line);}} }}
</style>
</head>
<body>
<header><h1>{html.escape(title)}</h1><span class="badge">{html.escape(badge)}</span></header>
<div class="wrap">
  <nav>{''.join(nav_items)}</nav>
  <main>{body}</main>
</div>
<footer>{html.escape(footer)}</footer>
<script>{mermaid_js}</script>
<script>
  (function() {{
    var ns = (typeof __esbuild_esm_mermaid_nm !== 'undefined' && __esbuild_esm_mermaid_nm.mermaid)
             || (window.__esbuild_esm_mermaid_nm && window.__esbuild_esm_mermaid_nm.mermaid)
             || window.mermaid;
    var mermaid = ns && (ns.default || ns);
    if (!mermaid || !mermaid.initialize) {{ console.error('mermaid nicht geladen'); return; }}
    mermaid.initialize({{ startOnLoad:false, theme:'neutral', securityLevel:'strict' }});
    var run = function() {{ mermaid.run({{ querySelector:'.mermaid' }}); }};
    if (document.readyState !== 'loading') run(); else document.addEventListener('DOMContentLoaded', run);
  }})();
</script>
</body>
</html>
"""
    dst.write_text(doc, encoding="utf-8")
    print(f"HTML gebaut: {dst}  ({len(mermaids)} Mermaid-Diagramm(e), {dst.stat().st_size // 1024} KB)")


def main(argv: list[str]) -> None:
    if len(argv) < 3:
        sys.exit('Aufruf: build_html.py QUELLE.md ZIEL.html "Titel" "Badge" "Fußzeile"')
    src, dst = Path(argv[1]), Path(argv[2])
    title = argv[3] if len(argv) > 3 else src.stem
    badge = argv[4] if len(argv) > 4 else "VV"
    footer = argv[5] if len(argv) > 5 else "VV · intern — nur für den Betreiber"
    build(src, dst, title, badge, footer)


if __name__ == "__main__":
    main(sys.argv)
