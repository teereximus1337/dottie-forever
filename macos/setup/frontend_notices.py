"""Verify downloadable frontend inputs and preserve bundled license notices."""

import json
from pathlib import Path
import sys


def verify(packages: dict) -> None:
    for relative, entry in sorted(packages.items()):
        if not relative:
            continue
        if not (
            relative.startswith("node_modules/")
            and entry.get("resolved", "").startswith("https://registry.npmjs.org/")
            and entry.get("integrity", "").startswith("sha512-")
        ):
            raise SystemExit(f"Unexpected source or missing integrity for {relative}")


def collect(frontend: Path, packages: dict, target: Path) -> None:
    parts = ["Dottie Forever frontend third-party notices\n"]
    for relative, entry in sorted(packages.items()):
        if not relative or entry.get("dev"):
            continue
        package = frontend / relative
        metadata = json.loads((package / "package.json").read_text())
        name, version = metadata["name"], metadata["version"]
        if version != entry["version"]:
            raise SystemExit(f"Expected {name} {entry['version']}, found {version}")
        parts.append(f"\n{name} {version}\nLicense: {metadata['license']}\n")
        notices = sorted(
            path for path in package.iterdir()
            if path.is_file() and path.name.lower().startswith(("license", "licence", "copying", "notice"))
        )
        if not notices and (name, version) == ("react-compiler-runtime", "1.0.0"):
            # npm's tarball omits LICENSE. Its gitHead identifies the React
            # source tree and the package source header points to root LICENSE.
            source = "https://github.com/facebook/react/blob/5c15c1cd3442f28044217703b5625f98c40042ee/LICENSE"
            parts.append(f"License source: {source}\n")
            notices = [Path(__file__).parent / "notices" / "react-compiler-runtime-1.0.0.txt"]
        if not notices:
            raise SystemExit(f"No license notice for {name} {version}")
        for notice in notices:
            parts.append(f"\n{notice.name}\n{notice.read_text(errors='replace')}\n")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(parts))


frontend = Path(sys.argv[2])
lock = json.loads((frontend / "package-lock.json").read_text())
if lock["lockfileVersion"] != 3:
    raise SystemExit("Expected npm lockfile format 3")
verify(lock["packages"])
if sys.argv[1] == "collect":
    collect(frontend, lock["packages"], Path(sys.argv[3]))
