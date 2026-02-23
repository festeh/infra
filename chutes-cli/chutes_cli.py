import argparse
import sys
import tomllib
from pathlib import Path

import httpx
import tomli_w
from rich.console import Console
from rich.table import Table

API_BASE = "https://llm.chutes.ai/v1"
CONFIG_PATH = Path(__file__).parent / "config.toml"
console = Console()


def load_config() -> dict:
    with open(CONFIG_PATH, "rb") as f:
        return tomllib.load(f)


def cmd_list(args: argparse.Namespace) -> None:
    resp = httpx.get(f"{API_BASE}/models", timeout=15)
    resp.raise_for_status()
    models = resp.json()["data"]

    models.sort(key=lambda m: m["id"].lower())

    table = Table(title=f"Chutes Models ({len(models)})", padding=(0, 1))
    table.add_column("Model", style="bold cyan", no_wrap=True)
    table.add_column("Quant", style="magenta")
    table.add_column("Ctx", justify="right", style="green")
    table.add_column("$/M in", justify="right", style="yellow")
    table.add_column("$/M out", justify="right", style="yellow")
    table.add_column("Flags", style="dim")

    for m in models:
        ctx = m.get("context_length") or m.get("max_model_len") or 0
        ctx_k = f"{ctx // 1024}k" if ctx else "?"
        in_price = m.get("pricing", {}).get("prompt", 0)
        out_price = m.get("pricing", {}).get("completion", 0)

        flags = []
        feats = m.get("supported_features", [])
        if "reasoning" in feats:
            flags.append("reason")
        if "tools" in feats:
            flags.append("tools")
        if "json_mode" in feats:
            flags.append("json")
        if "structured_outputs" in feats:
            flags.append("struct")
        if "vision" in feats or "image" in m.get("input_modalities", []):
            flags.append("vision")
        if m.get("confidential_compute"):
            flags.append("TEE")

        table.add_row(
            m["id"],
            m.get("quantization", "?"),
            ctx_k,
            f"{in_price:.3g}",
            f"{out_price:.3g}",
            " ".join(flags),
        )

    console.print(table)


def cmd_config(args: argparse.Namespace) -> None:
    cfg = load_config()["models"]

    for group_name in ["all", "group_1", "group_2"]:
        models = cfg.get(group_name, [])
        console.print(f"\n[bold]{group_name}[/bold] ({len(models)}):")
        for m in models:
            console.print(f"  {m}")


def _format_price(price: float) -> str:
    return f"${price:.3g}/M"


def _pick_replacement(
    dead_model: str,
    live_models: list[dict],
    config_models: set[str],
) -> str | None:
    """Interactively pick a replacement for a dead model."""
    dead_provider = dead_model.split("/")[0]

    def sort_key(m: dict) -> tuple[int, float]:
        provider = m["id"].split("/")[0]
        out_price = m.get("pricing", {}).get("completion", 0)
        # same provider first (0), then others (1); within group, most expensive first
        return (0 if provider == dead_provider else 1, -out_price)

    candidates = [m for m in live_models if m["id"] not in config_models]
    candidates.sort(key=sort_key)

    if not candidates:
        console.print("[red]  No candidates available.[/red]")
        return None

    for m in candidates:
        in_price = _format_price(m.get("pricing", {}).get("prompt", 0))
        out_price = _format_price(m.get("pricing", {}).get("completion", 0))
        console.print(f"  Candidate: [bold cyan]{m['id']}[/bold cyan]  (in {in_price}, out {out_price})")
        choice = console.input("  [y]es / [n]o / [o]ther: ").strip().lower()
        if choice == "y":
            return m["id"]
        if choice == "n":
            return None
        # 'o' or anything else → show next candidate

    console.print("[dim]  No more candidates.[/dim]")
    return None


def cmd_check(args: argparse.Namespace) -> None:
    resp = httpx.get(f"{API_BASE}/models", timeout=15)
    resp.raise_for_status()
    live_models = resp.json()["data"]
    live_ids = {m["id"] for m in live_models}

    cfg = load_config()
    models_cfg = cfg["models"]
    all_models = models_cfg.get("all", [])

    replacements: dict[str, str] = {}  # old → new
    config_set = set(all_models)

    for model in list(all_models):
        if model in live_ids:
            console.print(f"[green]  OK[/green] {model}")
            continue

        console.print(f"[red]  MISSING[/red] {model}")
        replacement = _pick_replacement(model, live_models, config_set)
        if replacement is None:
            break
        replacements[model] = replacement
        config_set.discard(model)
        config_set.add(replacement)

    if not replacements:
        if not any(m not in live_ids for m in all_models):
            console.print("\n[bold green]All models are live.[/bold green]")
        return

    # Apply replacements to all groups
    for group in ["all", "group_1", "group_2"]:
        if group not in models_cfg:
            continue
        models_cfg[group] = [replacements.get(m, m) for m in models_cfg[group]]

    with open(CONFIG_PATH, "wb") as f:
        tomli_w.dump(cfg, f)

    console.print("\n[bold]Replacements written to config.toml:[/bold]")
    for old, new in replacements.items():
        console.print(f"  {old} → [bold cyan]{new}[/bold cyan]")


def main() -> None:
    parser = argparse.ArgumentParser(prog="chutes", description="Manage Chutes AI models")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("list", aliases=["ls"], help="List available models")
    sub.add_parser("config", aliases=["cfg"], help="Show config")
    sub.add_parser("check", help="Check config models are still live")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    match args.command:
        case "list" | "ls":
            cmd_list(args)
        case "config" | "cfg":
            cmd_config(args)
        case "check":
            cmd_check(args)


if __name__ == "__main__":
    main()
