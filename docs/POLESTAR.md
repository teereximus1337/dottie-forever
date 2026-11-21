# WoW Forever reference with Polestar

Thanks to fitzforge and the Polestar contributors for building and publishing their guides, tooling, and quest data for WoW Forever. Dottie Forever is an independent community project. [Polestar on GitHub](https://github.com/fitzforge/polestar)

## Look up a route or quest

Open Polestar's guide library and pick your race, faction, or zone. To ask ChatGPT about a specific step, share the guide link and ask for the step it used. If ChatGPT cannot open the page, you can read it directly or give it the relevant facts. The site also publishes a plain-text index for assistants. [Guide library](https://polestar.guide/guides) · [Plain-text index](https://polestar.guide/llms.txt)

Try asking, “According to Polestar’s Alliance Riverglades guide, who starts The Lost Scout and where do I turn it in?” Steps 3–4 point to Scout Bolain east of Blackrock Pass and Cedric Dalton at Southern Watch. This example uses the web guide, which identifies itself as part of Polestar 0.4.0. [Riverglades guide](https://polestar.guide/guides/alliance/40-50/01b-riverglades)

Dottie Forever routes audio. The desktop build has no public Polestar connector or built-in quest database. Link retrieval and connected tools depend on the exact ChatGPT surface, account and session. Check for a source citation or tool result in the session where you intend to use it. [ChatGPT Voice availability](https://help.openai.com/en/articles/20001274-chatgpt-voice)

## Use the public database locally

The pinned reference baseline is `data-v2026.11.1`, published on November 3, 2026. It targets Forever client build `1.60.1.70532` and uses schema version `1`. The release offers a ZIP with JSONL, schemas and notices, a compressed SQLite alternative, and `SHA256SUMS`. [Database release](https://github.com/fitzforge/polestar/releases/tag/data-v2026.11.1) · [Artifact names and hashes](https://github.com/fitzforge/polestar/releases/expanded_assets/data-v2026.11.1) · [Dataset index](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/index.json)

Pick a release by the `data-v` prefix for a database lookup. The addon (`v*`), desktop updater (`client-v*`), Forge tools (`forge-v*`), in-game library (`lib-v*`), and contributor `data-pack` serve different purposes. Leveling routes and class or profession guides live in the guide library and in source `.guide` files under `guides/forever/`. Pin a guide tag or commit separately when you need a reproducible route. [Polestar releases](https://github.com/fitzforge/polestar/releases) · [Release streams](https://github.com/fitzforge/polestar/blob/next/docs/RELEASING.md#the-other-releases-forge-the-open-database-libforeverdata-the-data-pack) · [Guide sources](https://github.com/fitzforge/polestar/tree/next/guides/forever)

On macOS, paste this block into Terminal to put a checksum-verified copy in a new private folder for your user. It needs no game addon or ChatGPT credentials.

```sh
reference_root="$HOME/Library/Application Support/Dottie Forever Reference"
mkdir -p -m 700 "$reference_root" &&
reference_dir="$(mktemp -d "$reference_root/2026.11.1.XXXXXX")" &&
(
  set -eu
  umask 077
  cd "$reference_dir"
  asset=forever-db-2026.11.1.zip
  curl -fsSL "https://github.com/fitzforge/polestar/releases/download/data-v2026.11.1/$asset" -o "$asset"
  printf '%s  %s\n' '24a1072d69dd00c535ab1d13825354a1fd7a631d92cf8900538e81fca412919d' "$asset" |
    shasum -a 256 -c -
  unzip -q "$asset"
  printf 'Reference files saved in %s\n' "$reference_dir"
)
```

Run this lookup in the same Terminal with Python 3 available. Use a different numeric quest ID in place of `783` to look up another quest. In a new Terminal window, set `reference_dir` to the printed folder path in quotes.

```sh
python3 - "$reference_dir" 783 <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "forever-db"
index = json.loads((root / "index.json").read_text(encoding="utf-8"))
if (index["version"], index["schemaVersion"]) != ("2026.11.1", 1):
    raise SystemExit("Unexpected Polestar data or schema version.")

def records(table):
    with (root / "data" / f"{table}.jsonl").open(encoding="utf-8") as source:
        yield from map(json.loads, source)

quest_id = int(sys.argv[2])
quest = next((row for row in records("quest") if row["id"] == quest_id), None)
if quest is None:
    raise SystemExit(f"Quest {quest_id} is absent from this release.")

result = {"dataset": index["dataset"], "version": index["version"], "quest": quest}
for table in ("quest_start", "quest_end", "quest_objective", "quest_prereq"):
    result[table] = [row for row in records(table) if row["quest"] == quest_id]
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
```

The output includes quest and related record IDs. To resolve a giver or turn-in name, use the relation's `kind` to select `npc`, `object`, or `item`, then match its `id` in that table. The lookup reads files on disk and works offline after the download. Remove the printed folder when you no longer need that snapshot. [Table definitions and sample quest ID](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/README.md)

## Coverage and attribution

The pinned release publishes 5,287 of 5,408 quests. It has published objectives for 4,184 of those 5,408 and published drop sources for 1,771 of 9,441 items with a known dropper. A missing row or field means this snapshot offers no usable answer. The baseline has no recipe or reagent tables. Record the exact release and keep quest prerequisites, race, class and faction restrictions, and any confidence labels with the results. Spawn points are world coordinates and need the matching map frame for conversion to map percentages. [Coverage and changelog](https://github.com/fitzforge/polestar/releases/tag/data-v2026.11.1) · [Dataset README](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/README.md)

Polestar declares **GPL-3.0-only** for the base database tables and **CC BY 4.0** for its mechanics, steps, notes, schemas, corrections and database documentation. Keep the release's licenses, per-table manifest and NOTICE with local copies. If sharing material covered by CC BY 4.0, credit the creators and designated attribution parties, link the source and license, and identify changes. Before redistributing a GPL-covered artifact, review its applicable conditions for notices, modified versions and corresponding source. The upstream NOTICE credits independent sources with their own licenses and identifies Blizzard's underlying game material. Polestar's guide-pack exception leaves its own guide text outside the exception. Review those underlying rights before bundling any extract, guide content, or screenshot. [Data-package manifest](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/datapackage.json) · [Upstream credits](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/NOTICE.md) · [GPL v3](https://www.gnu.org/licenses/gpl-3.0.html) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) · [Guide-pack exception](https://github.com/fitzforge/polestar/blob/next/LICENSE-EXCEPTION.md)

## Proposed optional reference connection

1. Start with the official guide link and local lookup above. The desktop app does not configure a reference for your ChatGPT conversation. Use a public upstream link or a user-owned integration.
2. If people need in-session database search, prototype a separate, optional reader against a user-selected release folder. Verify archive and table hashes, schema, row IDs and joins. Return the source release, table and record IDs with each answer. Label any separately pinned guide source and preserve unknown values, conditions and confidence. Use synthetic records for automated tests. Pin upgrades explicitly and keep the previous folder for rollback.
3. Verify the read-only tools against the exact ChatGPT conversation surface before promising voice retrieval. ChatGPT's custom MCP setup depends on plan and workspace permissions. Its documented local-server route uses Secure MCP Tunnel for supported products. Polestar's upstream local MCP is a route-authoring tool with editing capabilities. A release needs a verified lookup path and a successful call in the target macOS voice session, with an observable source result. [Polestar planner MCP](https://github.com/fitzforge/polestar#the-route-planner-guides-played-on-the-real-map) · [Custom MCP connections in ChatGPT](https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt) · [ChatGPT Voice availability](https://help.openai.com/en/articles/20001274-chatgpt-voice)

Keep the integration proof separate from routing. A local lookup shows the data is readable. A text-chat tool call shows access in that chat. A voice claim requires a fresh call and source result in the exact voice session.
