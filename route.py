#!/usr/bin/env python3
"""Safely rebuild Xray outbounds and domain routing.

Default traffic always uses the first outbound (direct). Optional domain rules
can use a local WARP SOCKS5 listener or one Shadowsocks server.
"""

from __future__ import annotations

import argparse
import copy
import getpass
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from typing import Any, Iterable


DIRECT_TAG = "direct"
WARP_TAG = "warp"
SS_TAG = "shadowsocks"
SS_METHOD = "aes-128-gcm"
SUPPORTED_PREFIXES = (
    "domain:",
    "geosite:",
    "full:",
    "regexp:",
    "keyword:",
    "dotless:",
    "ext:",
)


class ManagerError(RuntimeError):
    pass


def eprint(message: str = "") -> None:
    print(message, file=sys.stderr)


def parse_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("端口必须是整数") from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("端口必须在 1-65535 之间")
    return port


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="安全重建 Xray 直连/WARP/Shadowsocks 出站与域名分流"
    )
    parser.add_argument(
        "--config", default="/etc/xray/config.json", help="Xray JSON 配置路径"
    )
    parser.add_argument("--service", default="xray", help="systemd 服务名")
    parser.add_argument(
        "--warp-port", type=parse_port, default=40000, help="本地 WARP SOCKS5 端口"
    )
    parser.add_argument("--xray-bin", help="Xray 可执行文件路径")
    parser.add_argument(
        "--no-restart", action="store_true", help="写入后不重启 systemd 服务"
    )
    return parser.parse_args()


def require_root() -> None:
    if os.geteuid() != 0:
        raise ManagerError("请使用 root 运行，例如：sudo ./xray-route-manager.py")


def load_config(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError as exc:
        raise ManagerError(f"配置不存在：{path}") from exc
    except json.JSONDecodeError as exc:
        raise ManagerError(
            f"原配置不是有效 JSON：第 {exc.lineno} 行，第 {exc.colno} 列：{exc.msg}"
        ) from exc
    except OSError as exc:
        raise ManagerError(f"无法读取配置 {path}：{exc}") from exc
    if not isinstance(data, dict):
        raise ManagerError("Xray 配置顶层必须是 JSON 对象")
    return data


def choose_mode(warp_port: int) -> tuple[bool, bool]:
    print("\n选择出站模式（未命中的流量始终直连）：")
    print("  1) 仅直连")
    print(f"  2) 直连 + WARP（SOCKS5 127.0.0.1:{warp_port}）")
    print("  3) 直连 + Shadowsocks")
    print("  4) 直连 + WARP + Shadowsocks")
    mapping = {
        "1": (False, False),
        "2": (True, False),
        "3": (False, True),
        "4": (True, True),
    }
    while True:
        choice = input("请输入 1-4 [1]: ").strip() or "1"
        if choice in mapping:
            return mapping[choice]
        print("输入无效，请输入 1、2、3 或 4。")


def choose_priority() -> list[str]:
    print("\nWARP 与 Shadowsocks 的规则可能重叠，请选择匹配优先级：")
    print("  1) WARP 优先")
    print("  2) Shadowsocks 优先")
    while True:
        choice = input("请输入 1 或 2 [1]: ").strip() or "1"
        if choice == "1":
            return [WARP_TAG, SS_TAG]
        if choice == "2":
            return [SS_TAG, WARP_TAG]
        print("输入无效，请输入 1 或 2。")


def prompt_nonempty(prompt: str, *, secret: bool = False) -> str:
    reader = getpass.getpass if secret else input
    while True:
        value = reader(prompt).strip()
        if value:
            return value
        print("此项不能为空。")


def prompt_port(prompt: str) -> int:
    while True:
        value = input(prompt).strip()
        try:
            return parse_port(value)
        except argparse.ArgumentTypeError as exc:
            print(exc)


def normalize_rule(raw: str) -> str:
    value = raw.strip()
    if not value:
        raise ValueError("空规则")
    if any(ord(char) < 32 for char in value):
        raise ValueError("规则不能包含控制字符")
    lowered = value.lower()
    if lowered.startswith(SUPPORTED_PREFIXES):
        prefix, body = value.split(":", 1)
        if not body.strip():
            raise ValueError(f"{prefix}: 后面缺少内容")
        # Xray prefixes are lower-case; regexp/ext bodies must retain case.
        return f"{prefix.lower()}:{body.strip()}"
    if value.startswith("*."):
        value = value[2:]
    if "://" in value or "/" in value:
        raise ValueError("这里只填写域名/规则，不要填写 URL 路径")
    if not value or value.startswith(".") or value.endswith("."):
        raise ValueError("域名格式无效")
    return f"domain:{value}"


def split_rule_line(line: str) -> Iterable[str]:
    # Commas make pasting lists convenient. A regexp containing a comma can be
    # entered on its own line; it is kept intact.
    if line.lstrip().lower().startswith("regexp:"):
        yield line
        return
    for item in line.replace("，", ",").split(","):
        if item.strip():
            yield item


def collect_rules(label: str, forbidden: set[str]) -> list[str]:
    print(f"\n输入走 {label} 的域名规则，空行结束。")
    print("可用：geosite:google、domain:example.com、full:example.com")
    print("也可直接输入 example.com 或 *.example.com，会转成 domain:example.com。")
    print("同一行可用英文/中文逗号分隔多个规则。")
    rules: list[str] = []
    seen: set[str] = set()
    while True:
        line = input(f"{label} 规则: ").strip()
        if not line:
            if rules:
                return rules
            print("至少需要一条规则；若不需要此出口，请重新运行并选择其他模式。")
            continue
        for raw in split_rule_line(line):
            try:
                rule = normalize_rule(raw)
            except ValueError as exc:
                print(f"  跳过 {raw!r}：{exc}")
                continue
            if rule in forbidden:
                print(f"  跳过 {rule}：已属于优先级更高的出口")
                continue
            if rule in seen:
                print(f"  跳过 {rule}：重复")
                continue
            seen.add(rule)
            rules.append(rule)
            print(f"  已添加：{rule}")


def socket_is_listening(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.7):
            return True
    except OSError:
        return False


def get_ss_server() -> dict[str, Any]:
    print("\nShadowsocks 加密方式固定为 aes-128-gcm。")
    while True:
        address = prompt_nonempty("Shadowsocks IP/域名: ")
        if address.startswith("[") and address.endswith("]"):
            address = address[1:-1]
        if (
            any(char.isspace() for char in address)
            or "://" in address
            or "/" in address
        ):
            print("地址只能是 IP 或域名，不能含空格、协议头或路径。")
            continue
        break
    port = prompt_port("Shadowsocks 端口: ")
    password = prompt_nonempty("Shadowsocks 密码（输入不回显）: ", secret=True)
    return {
        "address": address,
        "port": port,
        "method": SS_METHOD,
        "password": password,
    }


def current_outbound_summary(config: dict[str, Any]) -> str:
    outbounds = config.get("outbounds", [])
    if not isinstance(outbounds, list):
        return "原 outbounds 格式异常（将重建）"
    items: list[str] = []
    for outbound in outbounds:
        if not isinstance(outbound, dict):
            items.append("<异常项>")
            continue
        items.append(
            f"{outbound.get('tag', '<无 tag>')}({outbound.get('protocol', '<无协议>')})"
        )
    return ", ".join(items) if items else "<无>"


def make_outbounds(
    *,
    use_warp: bool,
    warp_port: int,
    ss_server: dict[str, Any] | None,
    schema: str,
) -> list[dict[str, Any]]:
    outbounds: list[dict[str, Any]] = [
        {"tag": DIRECT_TAG, "protocol": "freedom"}
    ]
    if use_warp:
        warp_settings: dict[str, Any]
        if schema == "modern":
            warp_settings = {"address": "127.0.0.1", "port": warp_port}
        else:
            warp_settings = {
                "servers": [{"address": "127.0.0.1", "port": warp_port}]
            }
        outbounds.append(
            {"tag": WARP_TAG, "protocol": "socks", "settings": warp_settings}
        )
    if ss_server is not None:
        if schema == "modern":
            ss_settings = copy.deepcopy(ss_server)
        else:
            ss_settings = {"servers": [copy.deepcopy(ss_server)]}
        outbounds.append(
            {"tag": SS_TAG, "protocol": "shadowsocks", "settings": ss_settings}
        )
    return outbounds


def make_routing(
    config: dict[str, Any], route_order: list[str], rules_by_tag: dict[str, list[str]]
) -> dict[str, Any]:
    old_routing = config.get("routing")
    routing: dict[str, Any] = {}
    if isinstance(old_routing, dict):
        for key in ("domainStrategy", "domainMatcher"):
            if key in old_routing:
                routing[key] = copy.deepcopy(old_routing[key])
    routing.setdefault("domainStrategy", "IPIfNonMatch")

    rules: list[dict[str, Any]] = []
    api = config.get("api")
    api_tag = api.get("tag") if isinstance(api, dict) else None
    if isinstance(api_tag, str) and api_tag:
        rules.append(
            {
                "type": "field",
                "inboundTag": [api_tag],
                "outboundTag": api_tag,
            }
        )
    for tag in route_order:
        domains = rules_by_tag.get(tag, [])
        if domains:
            rules.append(
                {"type": "field", "domain": copy.deepcopy(domains), "outboundTag": tag}
            )
    routing["rules"] = rules
    return routing


def build_candidate(
    config: dict[str, Any],
    *,
    use_warp: bool,
    warp_port: int,
    ss_server: dict[str, Any] | None,
    route_order: list[str],
    rules_by_tag: dict[str, list[str]],
    schema: str,
) -> dict[str, Any]:
    candidate = copy.deepcopy(config)
    candidate["outbounds"] = make_outbounds(
        use_warp=use_warp,
        warp_port=warp_port,
        ss_server=ss_server,
        schema=schema,
    )
    candidate["routing"] = make_routing(candidate, route_order, rules_by_tag)
    return candidate


def find_xray(explicit: str | None) -> str:
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    from_path = shutil.which("xray")
    if from_path:
        candidates.append(from_path)
    candidates.extend(("/usr/local/bin/xray", "/usr/bin/xray"))
    for candidate in candidates:
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise ManagerError("找不到 xray 可执行文件；可用 --xray-bin /实际路径 指定")


def write_json_temp(target: Path, data: dict[str, Any]) -> Path:
    try:
        handle = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            prefix=f".{target.name}.",
            suffix=".json",
            delete=False,
        )
        path = Path(handle.name)
        os.chmod(path, 0o600)
        with handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        return path
    except OSError as exc:
        raise ManagerError(f"无法在 {target.parent} 创建临时配置：{exc}") from exc


def run_xray_test(binary: str, config_path: Path) -> tuple[bool, str]:
    commands = (
        [binary, "run", "-test", "-config", str(config_path)],
        [binary, "-test", "-config", str(config_path)],
    )
    results: list[str] = []
    for command in commands:
        try:
            completed = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            results.append(f"{' '.join(command)}\n{exc}")
            continue
        output = completed.stdout.strip()
        results.append(
            f"{' '.join(command)}\n退出码 {completed.returncode}"
            + (f"\n{output}" if output else "")
        )
        if completed.returncode == 0:
            return True, results[-1]
    return False, "\n\n".join(results)


def validate_with_compatible_schema(
    *,
    target: Path,
    binary: str,
    base_config: dict[str, Any],
    use_warp: bool,
    warp_port: int,
    ss_server: dict[str, Any] | None,
    route_order: list[str],
    rules_by_tag: dict[str, list[str]],
) -> tuple[dict[str, Any], str]:
    failures: list[str] = []
    for schema in ("modern", "legacy"):
        candidate = build_candidate(
            base_config,
            use_warp=use_warp,
            warp_port=warp_port,
            ss_server=ss_server,
            route_order=route_order,
            rules_by_tag=rules_by_tag,
            schema=schema,
        )
        temp_path = write_json_temp(target, candidate)
        try:
            valid, details = run_xray_test(binary, temp_path)
        finally:
            temp_path.unlink(missing_ok=True)
        if valid:
            return candidate, schema
        failures.append(f"[{schema}]\n{details}")
    raise ManagerError(
        "新版和旧版出站格式都未通过 Xray 检查，原配置未修改。\n\n"
        + "\n\n".join(failures)
    )


def unique_backup_path(target: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = target.with_name(f"{target.name}.bak.{stamp}")
    if not base.exists():
        return base
    for number in range(1, 1000):
        candidate = target.with_name(f"{target.name}.bak.{stamp}.{number}")
        if not candidate.exists():
            return candidate
    raise ManagerError("无法生成不重复的备份文件名")


def atomic_install_json(target: Path, data: dict[str, Any]) -> None:
    original = target.stat()
    temp_path = write_json_temp(target, data)
    try:
        os.chmod(temp_path, stat.S_IMODE(original.st_mode))
        os.chown(temp_path, original.st_uid, original.st_gid)
        os.replace(temp_path, target)
        directory_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def restore_backup(target: Path, backup: Path) -> None:
    original = backup.stat()
    try:
        handle = tempfile.NamedTemporaryFile(
            mode="wb", dir=target.parent, prefix=f".{target.name}.restore.", delete=False
        )
        temp_path = Path(handle.name)
        with backup.open("rb") as source, handle:
            shutil.copyfileobj(source, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, stat.S_IMODE(original.st_mode))
        os.chown(temp_path, original.st_uid, original.st_gid)
        os.replace(temp_path, target)
    except Exception:
        if "temp_path" in locals():
            temp_path.unlink(missing_ok=True)
        raise


def systemctl(command: str, service: str) -> subprocess.CompletedProcess[str]:
    executable = shutil.which("systemctl")
    if not executable:
        raise ManagerError("找不到 systemctl")
    return subprocess.run(
        [executable, command, service],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=45,
        check=False,
    )


def restart_and_check(service: str) -> tuple[bool, str]:
    try:
        restarted = systemctl("restart", service)
        time.sleep(1)
        active = systemctl("is-active", service)
    except (OSError, subprocess.TimeoutExpired, ManagerError) as exc:
        return False, str(exc)
    messages = []
    if restarted.stdout.strip():
        messages.append(restarted.stdout.strip())
    if active.stdout.strip():
        messages.append(active.stdout.strip())
    ok = restarted.returncode == 0 and active.returncode == 0 and active.stdout.strip() == "active"
    return ok, "\n".join(messages) or f"restart={restarted.returncode}, active={active.returncode}"


def print_plan(
    config: dict[str, Any],
    *,
    use_warp: bool,
    warp_port: int,
    ss_server: dict[str, Any] | None,
    route_order: list[str],
    rules_by_tag: dict[str, list[str]],
) -> None:
    print("\n========== 修改预览 ==========")
    print(f"原出站：{current_outbound_summary(config)}")
    new_outbounds = ["direct(freedom，默认)"]
    if use_warp:
        new_outbounds.append(f"warp(socks5 127.0.0.1:{warp_port})")
    if ss_server is not None:
        new_outbounds.append(
            f"shadowsocks({ss_server['address']}:{ss_server['port']}，{SS_METHOD}，密码已隐藏)"
        )
    print("新出站：" + ", ".join(new_outbounds))
    print("未匹配规则：direct")
    if not route_order:
        print("代理规则：无（全部直连）")
    else:
        print("代理规则（由上到下优先匹配）：")
        for tag in route_order:
            print(f"  {tag}:")
            for rule in rules_by_tag.get(tag, []):
                print(f"    - {rule}")
    print("会删除：原有其他 outbounds、原有 routing.rules、routing.balancers")
    print("会保留：log/dns/api/stats/policy/inbounds 等其他顶层配置")
    print("================================")


def main() -> int:
    args = parse_args()
    require_root()

    requested = Path(args.config).expanduser()
    try:
        target = requested.resolve(strict=True)
    except FileNotFoundError as exc:
        raise ManagerError(f"配置不存在：{requested}") from exc
    config = load_config(target)
    binary = find_xray(args.xray_bin)
    if not args.no_restart and not shutil.which("systemctl"):
        raise ManagerError("找不到 systemctl；如只想写配置，可加 --no-restart")

    use_warp, use_ss = choose_mode(args.warp_port)
    ss_server = get_ss_server() if use_ss else None
    if use_warp and not socket_is_listening("127.0.0.1", args.warp_port):
        print(
            f"\n警告：当前无法连接 127.0.0.1:{args.warp_port}；"
            "配置仍可生成，但 WARP 可能不可用。"
        )

    if use_warp and use_ss:
        route_order = choose_priority()
    elif use_warp:
        route_order = [WARP_TAG]
    elif use_ss:
        route_order = [SS_TAG]
    else:
        route_order = []

    rules_by_tag: dict[str, list[str]] = {}
    higher_priority_rules: set[str] = set()
    labels = {WARP_TAG: "WARP", SS_TAG: "Shadowsocks"}
    for tag in route_order:
        rules = collect_rules(labels[tag], higher_priority_rules)
        rules_by_tag[tag] = rules
        higher_priority_rules.update(rules)

    print_plan(
        config,
        use_warp=use_warp,
        warp_port=args.warp_port,
        ss_server=ss_server,
        route_order=route_order,
        rules_by_tag=rules_by_tag,
    )
    if input("确认执行请输入 YES：").strip() != "YES":
        print("已取消，配置未修改。")
        return 0

    print("正在用本机 Xray 检查候选配置……")
    candidate, schema = validate_with_compatible_schema(
        target=target,
        binary=binary,
        base_config=config,
        use_warp=use_warp,
        warp_port=args.warp_port,
        ss_server=ss_server,
        route_order=route_order,
        rules_by_tag=rules_by_tag,
    )
    schema_name = "新版扁平格式" if schema == "modern" else "旧版 servers 格式"
    print(f"Xray 配置检查通过：{schema_name}")

    backup = unique_backup_path(target)
    try:
        shutil.copy2(target, backup)
        atomic_install_json(target, candidate)
    except OSError as exc:
        raise ManagerError(f"备份或写入失败：{exc}") from exc

    if args.no_restart:
        print(f"写入成功（未重启服务）。备份：{backup}")
        return 0

    ok, status = restart_and_check(args.service)
    if ok:
        print(f"完成：{args.service} 已重启，状态 active。")
        print(f"配置：{target}")
        print(f"备份：{backup}")
        return 0

    eprint(f"新配置写入后服务未正常运行：{status}")
    eprint("正在自动恢复原配置并重启服务……")
    try:
        restore_backup(target, backup)
    except OSError as exc:
        raise ManagerError(
            f"严重：自动恢复失败：{exc}\n请立即手动恢复：cp {backup} {target}"
        ) from exc
    rollback_ok, rollback_status = restart_and_check(args.service)
    if rollback_ok:
        raise ManagerError(
            f"新配置未能启动，已自动恢复原配置；{args.service} 当前 active。\n"
            f"失败时输出：{status}\n备份：{backup}"
        )
    raise ManagerError(
        "严重：已恢复原配置，但服务仍未 active。\n"
        f"首次失败：{status}\n恢复后状态：{rollback_status}\n备份：{backup}"
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        eprint("\n已中断，尚未完成的操作已停止。")
        raise SystemExit(130)
    except ManagerError as exc:
        eprint(f"错误：{exc}")
        raise SystemExit(1)
