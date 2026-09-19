#!/usr/bin/env bash
#
# mac-disk-cleanup.sh — macOS 磁盘空间体检 / 清理工具
#
# 默认只扫描不删除。确认无误后再加 --clean 真正执行。
#
#   ./mac-disk-cleanup.sh                  # 扫描报告（只读，绝对安全）
#   ./mac-disk-cleanup.sh --clean          # 清理「安全层」：纯可再生的开发缓存
#   ./mac-disk-cleanup.sh --clean --deep   # 再加「激进层」：Docker / 模拟器 / 快照 / 陈旧 node_modules
#   ./mac-disk-cleanup.sh --clean --yes    # 跳过交互确认
#   ./mac-disk-cleanup.sh --big            # 额外列出家目录里的超大文件
#
# 设计原则：
#   * 三层分级：安全层自动删、激进层要 --deep、敏感项永远只报告不删。
#   * 文稿/桌面/下载/照片库/iCloud/iOS 备份/Xcode Archives —— 任何情况下都不会被删除。
#   * 每一项删除前先打印它占多少空间。

set -uo pipefail

DRY_RUN=true
DEEP=false
ASSUME_YES=false
SHOW_BIG=false

for arg in "$@"; do
  case "$arg" in
    --clean)        DRY_RUN=false ;;
    --deep|--aggressive) DEEP=true ;;
    --yes|-y)       ASSUME_YES=true ;;
    --big)          SHOW_BIG=true ;;
    -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $arg（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "警告：本脚本是为 macOS 写的，当前系统是 $(uname -s)。" >&2
  echo "扫描仍可运行（大部分路径会显示为不存在），但请勿在非 macOS 上执行 --clean。" >&2
  echo
fi

TOTAL_KB=0
TILDE='~'   # 用变量承载，避免 bash 3.2/5 对替换串中反斜杠的处理差异
BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; RST=""; }

human() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

# 计算若干路径的总占用（KB）。-x 避免走进网络盘/外接卷。
size_of() {
  local total=0 kb p
  for p in "$@"; do
    [ -e "$p" ] || continue
    kb=$(du -skx -- "$p" 2>/dev/null | awk 'NR==1{print $1}')
    total=$(( total + ${kb:-0} ))
  done
  printf '%s' "$total"
}

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

# 只报告，不计入可回收总量，也永远不删
report() {
  local label="$1"; shift
  local kb; kb=$(size_of "$@")
  [ "${kb:-0}" -eq 0 ] && return 0
  printf '  %s%-44s %10s%s\n' "$DIM" "$label" "$(human "$kb")" "$RST"
}

# 可删除项
purge() {
  local label="$1"; shift
  local kb p; kb=$(size_of "$@")
  [ "${kb:-0}" -eq 0 ] && return 0
  if $DRY_RUN; then
    TOTAL_KB=$(( TOTAL_KB + kb ))
    printf '  %-44s %10s  %s(可清理)%s\n' "$label" "$(human "$kb")" "$YLW" "$RST"
    return 0
  fi
  printf '  %-44s %10s  ' "$label" "$(human "$kb")"
  for p in "$@"; do
    [ -e "$p" ] || continue
    # 安全闸门：绝不对空串、根目录、家目录本身动手
    case "$p" in
      ""|"/"|"$HOME"|"$HOME/"|"/System"*|"/Users") printf '%s跳过(受保护路径)%s ' "$RED" "$RST"; continue ;;
    esac
    rm -rf -- "$p" 2>/dev/null
  done
  # 以实际释放量为准，而不是假定删除成功
  local after freed; after=$(size_of "$@"); freed=$(( kb - after ))
  [ "$freed" -lt 0 ] && freed=0
  TOTAL_KB=$(( TOTAL_KB + freed ))
  if [ "$after" -eq 0 ]; then
    printf '%s已清理%s\n' "$GRN" "$RST"
  elif [ "$freed" -eq 0 ]; then
    printf '%s未能删除（被占用或受系统保护），已跳过%s\n' "$RED" "$RST"
  else
    printf '%s部分清理：释放 %s，剩余 %s 被占用%s\n' "$YLW" "$(human "$freed")" "$(human "$after")" "$RST"
  fi
}

# 运行一条命令式清理（brew cleanup 之类）
run_cmd() {
  local label="$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 0
  if $DRY_RUN; then
    printf '  %-44s %10s  %s(可执行)%s\n' "$label" "-" "$YLW" "$RST"
  else
    printf '  %-44s %10s  ' "$label" "-"
    "$@" >/dev/null 2>&1 && printf '%s完成%s\n' "$GRN" "$RST" || printf '%s跳过/失败%s\n' "$RED" "$RST"
  fi
}

printf '%s========== macOS 磁盘体检 ==========%s\n' "$BOLD" "$RST"
df -h / 2>/dev/null | awk 'NR==1||NR==2'
$DRY_RUN && printf '\n%s模式：扫描（只读，不会删除任何东西）%s\n' "$YLW" "$RST" \
         || printf '\n%s模式：清理（会真实删除）%s\n' "$RED" "$RST"
$DEEP && printf '%s已启用 --deep：包含激进层%s\n' "$RED" "$RST"

# --clean 是真删除，除非 --yes 或非交互环境，否则先要一次确认
if ! $DRY_RUN && ! $ASSUME_YES; then
  if [ -t 0 ]; then
    printf '\n%s即将真实删除上述缓存。继续？[y/N] %s' "$RED" "$RST"
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) printf '已取消。\n'; exit 0 ;;
    esac
  else
    printf '\n%s非交互环境下执行 --clean 需要显式加 --yes，已中止。%s\n' "$RED" "$RST"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 安全层
section "【安全层】纯可再生缓存 —— 删了只会下次重新生成"

purge "Xcode DerivedData（编译中间产物）"   "$HOME/Library/Developer/Xcode/DerivedData"
purge "Xcode 自身缓存"                      "$HOME/Library/Caches/com.apple.dt.Xcode"
purge "Xcode iOS DeviceSupport（旧版本）"   "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
purge "Xcode watchOS/tvOS DeviceSupport"    "$HOME/Library/Developer/Xcode/watchOS DeviceSupport" \
                                            "$HOME/Library/Developer/Xcode/tvOS DeviceSupport"
purge "CoreSimulator 缓存"                  "$HOME/Library/Developer/CoreSimulator/Caches"
purge "Swift Package Manager 缓存"          "$HOME/Library/Caches/org.swift.swiftpm"
purge "CocoaPods 缓存"                      "$HOME/Library/Caches/CocoaPods"
purge "Carthage 缓存"                       "$HOME/Library/Caches/org.carthage.CarthageKit"

purge "npm 缓存"                            "$HOME/.npm/_cacache"
purge "yarn 缓存"                           "$HOME/Library/Caches/Yarn"
purge "pnpm 缓存"                           "$HOME/Library/pnpm/store" "$HOME/.pnpm-store"
purge "pip 缓存"                            "$HOME/Library/Caches/pip"
purge "Homebrew 下载缓存"                   "$HOME/Library/Caches/Homebrew"
purge "Gradle 构建缓存"                     "$HOME/.gradle/caches/build-cache-1"
purge "Cargo registry 缓存"                 "$HOME/.cargo/registry/cache"
purge "Go 构建缓存"                         "$HOME/Library/Caches/go-build"
purge "Composer 缓存"                       "$HOME/.composer/cache" "$HOME/Library/Caches/composer"
purge "Puppeteer/Playwright 旧浏览器"       "$HOME/.cache/puppeteer" "$HOME/Library/Caches/ms-playwright"

purge "用户日志（~/Library/Logs）"          "$HOME/Library/Logs"/*
purge "崩溃报告"                            "$HOME/Library/Logs/DiagnosticReports"
purge "QuickLook 缩略图缓存"                "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"

run_cmd "brew cleanup -s（清旧版本+缓存）"  brew cleanup -s --prune=all

# ---------------------------------------------------------------- 激进层
section "【激进层】需要 --deep —— 可恢复，但重建要花时间/流量"
if $DEEP; then
  purge "废纸篓 ~/.Trash"                   "$HOME/.Trash"
  purge "整个 ~/Library/Caches 剩余部分"    "$HOME/Library/Caches"
  purge "Maven 本地仓库 ~/.m2/repository"   "$HOME/.m2/repository"
  purge "Gradle 全部缓存 ~/.gradle/caches"  "$HOME/.gradle/caches"
  purge "Go module 缓存"                    "$HOME/go/pkg/mod"

  run_cmd "删除不可用的 iOS 模拟器"          xcrun simctl delete unavailable
  run_cmd "Docker 清理未用镜像/容器/卷"      docker system prune -af --volumes

  # Time Machine 本地快照：常见的「空间凭空消失」元凶
  if command -v tmutil >/dev/null 2>&1; then
    snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
    if [ "${snaps:-0}" -gt 0 ]; then
      if $DRY_RUN; then
        printf '  %-44s %10s  %s(%s 个本地快照，可清理)%s\n' "Time Machine 本地快照" "-" "$YLW" "$snaps" "$RST"
      else
        printf '  %-44s %10s  ' "Time Machine 本地快照（$snaps 个）" "-"
        ok=0; fail=0
        while read -r d; do
          [ -n "$d" ] || continue
          if tmutil deletelocalsnapshots "$d" >/dev/null 2>&1; then ok=$((ok+1)); else fail=$((fail+1)); fi
        done < <(tmutil listlocalsnapshots / 2>/dev/null | sed 's/.*com\.apple\.TimeMachine\.//; s/\.local$//')
        if [ "$fail" -gt 0 ]; then
          printf '%s删除 %s 个，%s 个失败（需 sudo：sudo tmutil thinlocalsnapshots / 999999999999 4）%s\n' "$YLW" "$ok" "$fail" "$RST"
        else
          printf '%s已清理 %s 个%s\n' "$GRN" "$ok" "$RST"
        fi
      fi
    fi
  fi

  # 90 天未改动的 node_modules
  section "  陈旧 node_modules（90 天未改动）"
  found=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    found=1
    purge "  $(printf '%s' "${d/#$HOME/$TILDE}" | cut -c1-40)" "$d"
  done < <(find "$HOME" -maxdepth 6 -type d -name node_modules -mtime +90 -prune -print 2>/dev/null | head -40)
  [ "$found" -eq 0 ] && printf '  %s无%s\n' "$DIM" "$RST"
else
  printf '  %s（未启用，加 --deep 查看：废纸篓 / Docker / 模拟器 / TM 本地快照 / 陈旧 node_modules）%s\n' "$DIM" "$RST"
fi

# ---------------------------------------------------------------- 只报告
section "【只报告，脚本永不删除】需要你自己判断的大件"
report "iOS 设备备份（可能很大且珍贵）"  "$HOME/Library/Application Support/MobileSync/Backup"
report "Xcode Archives（发版存档）"      "$HOME/Library/Developer/Xcode/Archives"
report "iOS 模拟器设备数据"              "$HOME/Library/Developer/CoreSimulator/Devices"
report "下载文件夹"                      "$HOME/Downloads"
report "桌面"                            "$HOME/Desktop"
report "废纸篓"                          "$HOME/.Trash"
report "照片图库"                        "$HOME/Pictures/Photos Library.photoslibrary"
report "邮件数据"                        "$HOME/Library/Mail"
report "Docker 磁盘映像"                 "$HOME/Library/Containers/com.docker.docker/Data/vms" \
                                         "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data"
for app in /Applications/Install\ macOS*.app; do
  [ -e "$app" ] && report "macOS 安装器：$(basename "$app")" "$app"
done

# ---------------------------------------------------------------- 家目录概览
section "家目录占用 Top 15"
du -skx "$HOME"/* "$HOME"/.[!.]* 2>/dev/null | sort -rn | head -15 | while read -r kb path; do
  printf '  %-52s %10s\n' "${path/#$HOME/$TILDE}" "$(human "$kb")"
done

if $SHOW_BIG; then
  section "家目录中的超大文件（>500MB，跳过 iCloud/照片库）"
  find "$HOME" -type d \( -name '*.photoslibrary' -o -name 'Mobile Documents' -o -name '.Trash' \) -prune -o \
       -type f -size +500M -print 2>/dev/null | head -30 | while IFS= read -r f; do
    printf '  %-52s %10s\n' "$(printf '%s' "${f/#$HOME/$TILDE}" | cut -c1-52)" "$(human "$(size_of "$f")")"
  done
fi

# ---------------------------------------------------------------- 小结
printf '\n%s========== 小结 ==========%s\n' "$BOLD" "$RST"
if $DRY_RUN; then
  printf '可回收空间合计：%s%s%s\n' "$BOLD" "$(human "$TOTAL_KB")" "$RST"
  printf '\n下一步：\n'
  printf '  %s./%s --clean%s          真正清理安全层\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '  %s./%s --clean --deep%s   连激进层一起清\n' "$BOLD" "$(basename "$0")" "$RST"
  printf '\n%s提示：清理前建议退出 Xcode / Docker / 浏览器，避免正在使用的缓存被占用。%s\n' "$DIM" "$RST"
else
  printf '本次已清理约：%s%s%s\n' "$BOLD" "$(human "$TOTAL_KB")" "$RST"
  df -h / 2>/dev/null | awk 'NR==2{printf "当前可用：%s（使用率 %s）\n", $4, $5}'
fi
