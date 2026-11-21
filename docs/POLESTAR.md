# WoW Forever reference with Polestar

Thanks to fitzforge and the Polestar contributors for building and publishing their guides, tooling, and quest data for WoW Forever. Dottie Forever is an independent community project. [Polestar on GitHub](https://github.com/fitzforge/polestar)

## Look up a route or quest

Open Polestar's guide library and pick your race, faction, or zone. Share a guide link with your Dot and ask it to cite the step it used. Polestar publishes a plain-text index and Markdown copies of its guides. [Guide library](https://polestar.guide/guides) · [Polestar's guide for AI assistants](https://polestar.guide/docs/players/ai-assistants)

Try asking, “According to Polestar’s Alliance Riverglades guide, who starts The Lost Scout and where do I turn it in?” Steps 3–4 point to Scout Bolain east of Blackrock Pass and Cedric Dalton at Southern Watch. This example uses the web guide, which identifies itself as part of Polestar 0.4.0. [Riverglades guide](https://polestar.guide/guides/alliance/40-50/01b-riverglades.md)

Dottie Forever routes audio. You can ask your Dot to read Polestar through its own browser or cloud computer. [ChatGPT Dots cloud computer](https://learn.chatgpt.com/docs/dots/computers-and-apps#use-the-cloud-computer)

## Use the public database locally

The pinned release is `data-v2026.11.1`, published November 3, 2026 at commit `25bab52a178ee721302bdbf26c083686c30101e9`. The archive identifies Forever client build `1.60.1.70532`, schema `1`, and producer commit `6d0de256e66674512e453a2990076d84f7e979bb`. The release provides the JSONL ZIP, a compressed SQLite alternative, and `SHA256SUMS`. [Database release](https://github.com/fitzforge/polestar/releases/tag/data-v2026.11.1) · [Artifact names and hashes](https://github.com/fitzforge/polestar/releases/expanded_assets/data-v2026.11.1) · [Dataset index](https://github.com/fitzforge/polestar/blob/25bab52a178ee721302bdbf26c083686c30101e9/forever-db/index.json)

Pick a release by the `data-v` prefix for a database lookup. The addon (`v*`), desktop updater (`client-v*`), Forge tools (`forge-v*`), in-game library (`lib-v*`), and contributor `data-pack` serve different purposes. Leveling routes and class or profession guides live in the guide library and in source `.guide` files under `guides/forever/`. Pin a guide tag or commit separately when you need a reproducible route. [Polestar releases](https://github.com/fitzforge/polestar/releases) · [Release streams](https://github.com/fitzforge/polestar/blob/next/docs/RELEASING.md#the-other-releases-forge-the-open-database-libforeverdata-the-data-pack) · [Guide sources](https://github.com/fitzforge/polestar/tree/next/guides/forever)

Run this block in a shell on macOS or Linux with `curl` and Python 3. It verifies the archive before extraction and prints the absolute path to the new private data folder. Keep that path for the lookup below.

```sh
(
  set -eu
  umask 077
  reference_root="${XDG_DATA_HOME:-$HOME/.local/share}/dottie-forever-reference"
  mkdir -p "$reference_root"
  reference_dir="$(mktemp -d "$reference_root/2026.11.1.XXXXXX")"
  cd "$reference_dir"
  asset=forever-db-2026.11.1.zip
  curl -fsSL --proto '=https' --proto-redir '=https' \
    "https://github.com/fitzforge/polestar/releases/download/data-v2026.11.1/$asset" -o "$asset"
  python3 - "$asset" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys
from zipfile import ZipFile

archive = Path(sys.argv[1])
if sha256(archive.read_bytes()).hexdigest() != "24a1072d69dd00c535ab1d13825354a1fd7a631d92cf8900538e81fca412919d":
    raise SystemExit("Polestar archive checksum does not match the pinned release.")

with ZipFile(archive) as release:
    index = json.loads(release.read("forever-db/index.json"))
    expected = ("polestar-data-forever", "2026.11.1", "1.60.1.70532", 1)
    if tuple(index[key] for key in ("dataset", "version", "clientBuild", "schemaVersion")) != expected:
        raise SystemExit("Unexpected Polestar dataset, version, client build or schema.")
    release.extractall()

print(f"Verified Polestar {index['version']} for Forever {index['clientBuild']}.")
print(f"Reference folder: {Path('forever-db').resolve()}")
PY
)
```

Replace `PRINTED_REFERENCE_FOLDER` with the printed absolute path, keeping the quotes. Replace `783` with another numeric quest ID or exact quest title to look up a different quest. The query checks the relevant table hashes and resolves the giver and turn-in records when their names are present.

```sh
python3 - 'PRINTED_REFERENCE_FOLDER' 783 <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
index = json.loads((root / "index.json").read_text(encoding="utf-8"))
if (index["version"], index["clientBuild"], index["schemaVersion"]) != ("2026.11.1", "1.60.1.70532", 1):
    raise SystemExit("Unexpected Polestar version, client build or schema.")

manifest = json.loads((root / "datapackage.json").read_text(encoding="utf-8"))
hashes = {resource["name"]: resource["hash"] for resource in manifest["resources"]}

def records(table):
    contents = (root / "data" / f"{table}.jsonl").read_bytes()
    if f"sha256:{sha256(contents).hexdigest()}" != hashes[table]:
        raise SystemExit(f"Polestar table checksum mismatch: {table}")
    yield from map(json.loads, contents.splitlines())

query = sys.argv[2].strip().casefold()
quests = [row for row in records("quest") if str(row["id"]) == query or row.get("title", "").casefold() == query]
if len(quests) != 1:
    matches = [row["id"] for row in quests]
    raise SystemExit(f"Expected one quest. Matching IDs: {matches}.")

quest = quests[0]
result = {
    "source": "https://github.com/fitzforge/polestar/releases/tag/data-v2026.11.1",
    "client_build": index["clientBuild"],
    "quest": quest,
}
for table in ("quest_start", "quest_end"):
    relations = [row for row in records(table) if row["quest"] == quest["id"]]
    for relation in relations:
        kind = relation["kind"]
        if kind in ("npc", "object", "item"):
            entity = next((row for row in records(kind) if row["id"] == relation["id"]), {})
            if entity.get("name"):
                relation["name"] = entity["name"]
    result[table] = relations
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
```

The lookup works offline after the download. To remove this snapshot, delete the `2026.11.1.*` parent of its printed `forever-db` folder. [Polestar table definitions](https://github.com/fitzforge/polestar/blob/25bab52a178ee721302bdbf26c083686c30101e9/forever-db/README.md)

## Set up a tester's Dot VM

In the tester's own Dot conversation, send this instruction with the download block above. The Dot can run it on its cloud computer or use a cloud task on that computer. Check the result for the verified release, build and absolute path before opening a call. [Using your Dot's cloud computer](https://learn.chatgpt.com/docs/dots/computers-and-apps#use-the-cloud-computer)

> Run the attached shell block on your own cloud computer. Set up one private copy of Polestar's pinned WoW Forever data and tell me the verified release, client build and absolute path. Keep that path for a lookup from this Dot conversation. If you can't run the block on your cloud computer, tell me which step is blocked. Leave any other references, tasks and connections alone.

Then paste the lookup block with this instruction so Dot can run it when asked.

> Use this read-only query on the same cloud computer when I ask for a pinned Polestar quest lookup. Substitute the verified folder path and my quest ID or exact quest title. Return the giver and turn-in in a short sentence, then the release link and source record IDs. If you cannot read the saved snapshot in a call, tell me.

## Verify in the same voice session

1. In that Dot conversation in the ChatGPT desktop app, select the phone button. Start routing as described in the [README](../README.md#ask-solo). In Discord, ask a guildmate to run the question after the wake phrase so everyone can confirm the reply. [Message or call your Dot](https://learn.chatgpt.com/docs/dots#message-or-call-your-dot)
2. Say, “Using the pinned Polestar WoW Forever database, who gives A Threat Within and who do I turn it in to? Tell me the release and record IDs.” Leave the call open until you hear the result. If your Dot delegates a lookup, open its activity and confirm it read the saved folder and checked the `quest`, `quest_start`, `quest_end` and `npc` tables during this call.
3. Check for the spoken answer “Deputy Willem gives it, and you turn it in to Marshal McBride.” The source is Polestar `data-v2026.11.1`, quest `783`, NPC `823` and NPC `197`. Save the timestamp, observed source result, and who heard the answer. If you only receive a text response, the session ends before the result, or the source result is unavailable, record the voice check as pending.

## Coverage and attribution

The pinned release publishes 5,287 of 5,408 quests. It has published objectives for 4,184 of those 5,408 and published drop sources for 1,771 of 9,441 items with a known dropper. A missing row or field means this snapshot offers no usable answer. The baseline has no recipe or reagent tables. Record the exact release and keep quest prerequisites, race, class and faction restrictions, and any confidence labels with the results. Spawn points are world coordinates and need the matching map frame for conversion to map percentages. [Coverage and changelog](https://github.com/fitzforge/polestar/releases/tag/data-v2026.11.1) · [Dataset README](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/README.md)

Polestar declares **GPL-3.0-only** for the base database tables and **CC BY 4.0** for its mechanics, steps, notes, schemas, corrections and database documentation. Keep the release's licenses, per-table manifest and NOTICE with local copies. If sharing material covered by CC BY 4.0, credit the creators and designated attribution parties, link the source and license, and identify changes. Before redistributing a GPL-covered artifact, review its applicable conditions for notices, modified versions and corresponding source. The upstream NOTICE credits independent sources with their own licenses and identifies Blizzard's underlying game material. Polestar's guide-pack exception leaves its own guide text outside the exception. Review those underlying rights before bundling any extract, guide content, or screenshot. [Data-package manifest](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/datapackage.json) · [Upstream credits](https://github.com/fitzforge/polestar/blob/data-v2026.11.1/forever-db/NOTICE.md) · [GPL v3](https://www.gnu.org/licenses/gpl-3.0.html) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) · [Guide-pack exception](https://github.com/fitzforge/polestar/blob/next/LICENSE-EXCEPTION.md)

Call capabilities depend on your account, workspace and session. A Dot cloud task can establish access to the snapshot. A live test also requires the sourced answer to be audible in the active call. [ChatGPT Voice availability](https://help.openai.com/en/articles/20001274-chatgpt-voice)
