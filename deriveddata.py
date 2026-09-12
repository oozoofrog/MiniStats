#!/usr/bin/python3
"""Xcode DerivedData 용량 조회 및 오래된 캐시 정리 (외부 의존성 없음)."""

import argparse
from contextlib import nullcontext
from datetime import datetime, timezone
from multiprocessing import Pool
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from xml.parsers.expat import ExpatError


SHARED = {
    "ModuleCache.noindex", "CompilationCache.noindex", "SDKStatCaches.noindex",
    "SDKExplicitPrecompiledModules", "SymbolCache.noindex",
}


def human_size(size):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}"
        size /= 1024


def default_roots():
    roots = [Path.home() / "Library/Developer/Xcode/DerivedData"]
    result = subprocess.run(
        ["/usr/bin/defaults", "read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode == 0 and result.stdout.strip():
        custom = Path(result.stdout.strip()).expanduser()
        if custom.is_absolute():
            roots.append(custom)
        else:
            print("참고: 상대 경로로 설정된 DerivedData는 --root로 지정하세요.", file=sys.stderr)
    return roots


def inspect(path):
    """Count allocated blocks and newest modification without following symlinks."""
    initial = path.lstat()
    size, latest = 0, initial.st_mtime
    seen, pending = set(), [path]
    while pending:
        current = pending.pop()
        try:
            item = current.lstat()
        except (FileNotFoundError, NotADirectoryError):
            # A build removed an entry during the scan: keep this entire cache.
            latest = max(latest, time.time())
            continue
        if item.st_dev != initial.st_dev:
            raise OSError(f"다른 파일시스템이 포함되어 있어 건너뜁니다: {current}")
        latest = max(latest, item.st_mtime)
        key = (item.st_dev, item.st_ino)
        if key in seen:
            continue
        seen.add(key)
        size += item.st_blocks * 512
        if stat.S_ISDIR(item.st_mode):
            try:
                with os.scandir(current) as entries:
                    pending.extend(Path(entry.path) for entry in entries)
            except (FileNotFoundError, NotADirectoryError):
                latest = max(latest, time.time())

    kind, workspace = "기타", ""
    if stat.S_ISDIR(initial.st_mode):
        info_path = path / "info.plist"
        if info_path.is_symlink():
            raise OSError(f"info.plist가 심볼릭 링크입니다: {info_path}")
        try:
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)
        except FileNotFoundError:
            info = {}
        except (ValueError, TypeError, OverflowError, ExpatError) as exc:
            raise OSError(f"info.plist 해석 실패: {info_path}") from exc
        if not isinstance(info, dict):
            raise OSError(f"info.plist가 사전 형식이 아닙니다: {info_path}")
        workspace = info.get("WorkspacePath", "")
        if not isinstance(workspace, str):
            raise OSError(f"WorkspacePath가 문자열이 아닙니다: {info_path}")
        accessed = info.get("LastAccessedDate")
        if isinstance(accessed, datetime):
            latest = max(latest, accessed.replace(tzinfo=timezone.utc).timestamp())
        elif accessed is not None:
            raise OSError(f"LastAccessedDate가 날짜 형식이 아닙니다: {info_path}")
        if path.name in SHARED:
            kind = "공용"
        elif workspace or (
            re.fullmatch(r".+-[a-z]{28}", path.name)
            and any((path / name).is_dir() for name in ("Build", "Logs", "Index.noindex", "SourcePackages"))
        ):
            kind = "프로젝트"
    return dict(path=path, size=size, latest=latest, kind=kind, workspace=workspace,
                identity=(initial.st_dev, initial.st_ino))


def eligible(item, cutoff, include_shared):
    return item["latest"] < cutoff and (
        item["kind"] == "프로젝트" or (include_shared and item["kind"] == "공용")
    )


def ensure_idle():
    result = subprocess.run(
        ["/bin/ps", "-axo", "comm="], capture_output=True, text=True, check=True,
    )
    active = {Path(line.strip()).name for line in result.stdout.splitlines()} & {"Xcode", "xcodebuild"}
    if active:
        raise OSError("정리하려면 먼저 종료하세요: " + ", ".join(sorted(active)))


def ignore_interrupt():
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def clean(items, cutoff, include_shared):
    if not shutil.rmtree.avoids_symlink_attacks:
        raise OSError("이 Python에서는 안전한 디렉터리 삭제를 지원하지 않습니다.")
    removed, total = 0, 0
    for item in items:
        ensure_idle()
        path = item["path"]
        if path.is_symlink() or path.resolve() != path or os.path.ismount(path):
            raise OSError(f"삭제 경로가 변경되었거나 마운트 지점입니다: {path}")
        # Recheck all activity immediately before deleting; abort on any read error.
        fresh = inspect(path)
        if fresh["identity"] != item["identity"] or not eligible(fresh, cutoff, include_shared):
            print(f"유지 (조회 이후 변경됨): {path}")
            continue
        shutil.rmtree(path)
        removed += 1
        total += fresh["size"]
        print(f"삭제: {path} ({human_size(fresh['size'])})", flush=True)
    print(f"정리 완료: {removed}개, 삭제한 항목의 할당 용량 합계 {human_size(total)}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""예시:
  deriveddata                          # 전체 용량 + 8시간 이상 된 정리 후보 조회
  deriveddata --hours 24               # 24시간 기준 미리보기 (삭제 없음)
  deriveddata --days 7                 # 7일 기준 미리보기
  deriveddata --jobs 4                 # 최대 4개 프로젝트를 동시에 조회
  deriveddata --clean                  # 8시간 기준 후보를 영구 삭제
  deriveddata --include-shared --clean # 오래된 공용 캐시도 함께 삭제
  deriveddata --root /Volumes/SSD/DerivedData

기준: info.plist의 LastAccessedDate와 모든 하위 항목의 수정 시각 중 최신 값.
--root 생략 시 기본 위치와 Xcode 전역 사용자 지정 위치를 조회합니다.
프로젝트별 상대 경로나 xcodebuild -derivedDataPath 위치는 --root로 지정하세요.
--root에는 저장 폴더 또는 info.plist가 있는 개별 프로젝트 캐시를 지정하세요.
공용 캐시는 기본적으로 보존하며, 미확인 항목과 심볼릭 링크는 삭제하지 않습니다.
정리 전에 Xcode와 xcodebuild를 종료하고, 정리 중에는 새 빌드를 시작하지 마세요.
용량은 할당 블록 기준이며 APFS 공유 블록 등으로 실제 확보 공간과 다를 수 있습니다.
""",
    )
    period = parser.add_mutually_exclusive_group()
    period.add_argument("--hours", type=int, metavar="N", help="정리 기준 시간, 1 이상 (기본: 8)")
    period.add_argument("--days", type=int, metavar="N", help="정리 기준 일수, 1 이상 (--hours 대신 사용)")
    parser.add_argument("--clean", action="store_true", help="미리보기에 표시되는 정리 후보를 확인 질문 없이 영구 삭제")
    parser.add_argument("--include-shared", action="store_true", help="공용 캐시도 기간 기준에 따라 정리 후보에 포함")
    parser.add_argument("--root", action="append", type=Path, metavar="PATH", help="DerivedData 저장 폴더 또는 개별 캐시 (반복 가능, 기본 경로 대신 사용)")
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1), metavar="N", help="동시 조회 프로세스 수 (기본: 최대 4, 1이면 순차 조회)")
    parser.add_argument("--json", action="store_true", help="메뉴바 앱 등에 사용할 JSON 조회 결과 출력 (삭제와 함께 사용 불가)")
    parser.add_argument("--only-path", action="append", metavar="PATH", help="조회된 후보 중 지정한 절대 경로만 삭제 (반복 가능, --clean 필요)")
    args = parser.parse_args(argv)
    if args.only_path and not args.clean:
        parser.error("--only-path는 --clean과 함께 사용하세요.")
    if args.json and args.clean:
        parser.error("--json은 조회 전용입니다. --clean과 함께 사용할 수 없습니다.")
    if any(value is not None and value < 1 for value in (args.hours, args.days)):
        parser.error("--hours와 --days는 1 이상의 정수여야 합니다.")
    if args.jobs < 1:
        parser.error("--jobs는 1 이상의 정수여야 합니다.")
    hours = args.days * 24 if args.days is not None else (args.hours if args.hours is not None else 8)
    period_label = f"{args.days}일" if args.days is not None else f"{hours}시간"
    now = time.time()
    cutoff = now - hours * 3600
    items, visited = [], set()
    try:
        if args.clean:
            ensure_idle()
        for raw_root in args.root or default_roots():
            root = raw_root.expanduser().resolve()
            if root in visited:
                continue
            if any(root in previous.parents or previous in root.parents for previous in visited):
                raise OSError(f"--root 경로가 서로 포함되어 있습니다: {root}")
            visited.add(root)
            if root in {Path("/"), Path.home(), Path.home() / "Library", Path.home() / "Library/Developer", Path.home() / "Library/Developer/Xcode"}:
                raise OSError(f"DerivedData 저장 폴더를 정확히 지정하세요: {root}")
            if not root.exists() and not args.root:
                print(f"없음: {root}", file=sys.stderr)
                continue
            print(f"조회 중: {root}", file=sys.stderr, flush=True)
            paths = [root] if (root / "info.plist").is_file() else sorted(root.iterdir())
            jobs = min(args.jobs, len(paths))
            # The parent handles Ctrl-C; Pool terminates readers on interruption/error.
            with Pool(jobs, initializer=ignore_interrupt) if jobs > 1 else nullcontext() as pool:
                results = pool.imap_unordered(inspect, paths) if pool else map(inspect, paths)
                for index, item in enumerate(results, 1):
                    if sys.stderr.isatty():
                        print(f"\r  완료 {index}/{len(paths)} {item['path'].name[:70]:70}", end="", file=sys.stderr, flush=True)
                    items.append(item)
            if sys.stderr.isatty():
                print(file=sys.stderr)
        items.sort(key=lambda item: (-item["size"], str(item["path"])))
        candidates = [item for item in items if eligible(item, cutoff, args.include_shared)]
        if args.only_path:
            selected = set(args.only_path)
            allowed = {str(item["path"]) for item in candidates}
            if not selected <= allowed:
                raise OSError("선택한 항목이 없거나 더 이상 정리 후보가 아닙니다. 다시 조회하세요: " + ", ".join(sorted(selected - allowed)))
            candidates = [item for item in candidates if str(item["path"]) in selected]
        if args.json:
            print(json.dumps({
                "generated_at": now, "hours": hours,
                "total_bytes": sum(item["size"] for item in items),
                "candidate_bytes": sum(item["size"] for item in candidates),
                "items": [dict(path=str(item["path"]), size=item["size"], latest=item["latest"],
                               kind=item["kind"], workspace=item["workspace"],
                               candidate=eligible(item, cutoff, args.include_shared)) for item in items],
            }, ensure_ascii=False))
            return 0
        print(f"{'SIZE':>12}  {'AGE':>10}  {'LAST ACTIVITY':19}  상태 / 폴더")
        for item in items:
            age = max(0, int((now - item["latest"]) / 3600))
            age_label = f"{age // 24}d {age % 24:02}h"
            date = datetime.fromtimestamp(item["latest"]).strftime("%Y-%m-%d %H:%M:%S")
            status = "정리 후보" if eligible(item, cutoff, args.include_shared) else "유지"
            print(f"{human_size(item['size']):>12}  {age_label:>10}  {date}  {status} [{item['kind']}] {item['path']}")
            if item["workspace"]:
                print(f"{'':47}프로젝트: {item['workspace']}")
        print(f"\n전체: {len(items)}개 / {human_size(sum(item['size'] for item in items))}")
        print(f"{period_label} 기준 정리 후보: {len(candidates)}개 / {human_size(sum(item['size'] for item in candidates))}")
        if args.clean:
            clean(candidates, cutoff, args.include_shared)
        else:
            print("미리보기입니다. 삭제하려면 같은 옵션에 --clean을 추가하세요.")
        return 0
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"오류: {exc}\n작업을 중단했습니다. 위에 '삭제:'로 표시된 항목만 삭제되었습니다.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n중단했습니다. 삭제 진행 중이었다면 일부 항목만 삭제되었을 수 있습니다.", file=sys.stderr)
        sys.exit(130)
