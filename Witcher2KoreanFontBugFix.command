#!/bin/zsh
set -u

readonly PATCH_FONT_REL='CookedPC/globals/gui/fonts.swf'
readonly PATCH_CSV_REL='CookedPC/globals/gui/fonts/fonts.csv'
readonly SOURCE_ARCHIVE_REL='CookedPC/krbr.dzip'

die() {
  print -u2 -- "오류: $1"
  return 1
}

run_extractor() {
  local archive="$1"
  local output="$2"

  /usr/bin/osascript -l JavaScript - "$archive" "$output" 2>/dev/null <<'JXA'
ObjC.import('Foundation');

const BLOCK_SIZE = 0x10000;
const TARGET = "globals\\gui\\fonts_kr.swf";

function requireRange(bytes, offset, length) {
  if (offset < 0 || length < 0 || offset + length > bytes.length) {
    throw new Error('invalid archive');
  }
}

function readU16(bytes, offset) {
  requireRange(bytes, offset, 2);
  return Number(bytes[offset]) | (Number(bytes[offset + 1]) << 8);
}

function readU32(bytes, offset) {
  requireRange(bytes, offset, 4);
  return (Number(bytes[offset]) + Number(bytes[offset + 1]) * 0x100 +
    Number(bytes[offset + 2]) * 0x10000 + Number(bytes[offset + 3]) * 0x1000000);
}

function readBigU64(bytes, offset) {
  requireRange(bytes, offset, 8);
  let value = 0n;
  for (let index = 7; index >= 0; index -= 1) {
    value = (value << 8n) | BigInt(Number(bytes[offset + index]));
  }
  return value;
}

function checkedNumber(value) {
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error('invalid archive');
  }
  return Number(value);
}

function decodeLzf(input, expectedLimit) {
  const output = new Uint8Array(expectedLimit);
  let inputOffset = 0;
  let outputOffset = 0;
  while (inputOffset < input.length) {
    const control = input[inputOffset++];
    if (control < 32) {
      const length = control + 1;
      if (inputOffset + length > input.length || outputOffset + length > expectedLimit) {
        throw new Error('invalid archive');
      }
      output.set(input.subarray(inputOffset, inputOffset + length), outputOffset);
      inputOffset += length;
      outputOffset += length;
      continue;
    }
    let length = control >> 5;
    let distance = (control & 0x1F) << 8;
    if (length === 7) {
      if (inputOffset >= input.length) throw new Error('invalid archive');
      length += input[inputOffset++];
    }
    if (inputOffset >= input.length) throw new Error('invalid archive');
    length += 2;
    distance |= input[inputOffset++];
    let reference = outputOffset - 1 - distance;
    if (reference < 0 || outputOffset + length > expectedLimit) {
      throw new Error('invalid archive');
    }
    for (let index = 0; index < length; index += 1) {
      output[outputOffset++] = output[reference++];
    }
  }
  return output.slice(0, outputOffset);
}

function parseEntries(bytes) {
  requireRange(bytes, 0, 32);
  if (String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) !== 'DZIP') {
    throw new Error('invalid archive');
  }
  if (readU32(bytes, 4) < 2) {
    throw new Error('invalid archive');
  }

  const entryCount = readU32(bytes, 8);
  const tableOffset = checkedNumber(readBigU64(bytes, 16));
  if (tableOffset < 32 || tableOffset > bytes.length) {
    throw new Error('invalid archive');
  }

  let cursor = tableOffset;
  for (let entryIndex = 0; entryIndex < entryCount; entryIndex += 1) {
    const storedNameLength = readU16(bytes, cursor);
    cursor += 2;
    requireRange(bytes, cursor, storedNameLength);

    if (storedNameLength === 0 || bytes[cursor + storedNameLength - 1] !== 0) {
      throw new Error('invalid archive');
    }
    const nameLength = storedNameLength - 1;
    let isTarget = nameLength === TARGET.length;
    for (let nameIndex = 0; isTarget && nameIndex < nameLength; nameIndex += 1) {
      isTarget = Number(bytes[cursor + nameIndex]) === TARGET.charCodeAt(nameIndex);
    }
    cursor += storedNameLength;

    readBigU64(bytes, cursor);
    cursor += 8;
    const size = readBigU64(bytes, cursor);
    cursor += 8;
    const offset = readBigU64(bytes, cursor);
    cursor += 8;
    const compressedSize = readBigU64(bytes, cursor);
    cursor += 8;

    if (isTarget) {
      const target = {
        size: checkedNumber(size),
        offset: checkedNumber(offset),
        compressedSize: checkedNumber(compressedSize)
      };
      return { entry: target, tableOffset: tableOffset };
    }
  }

  throw new Error('invalid archive');
}

function extractEntry(bytes, entry, tableOffset) {
  if (entry.offset > tableOffset || entry.compressedSize > tableOffset - entry.offset) {
    throw new Error('invalid archive');
  }
  const blockCount = Math.ceil(entry.size / BLOCK_SIZE);
  requireRange(bytes, entry.offset, blockCount * 4);

  const boundaries = [];
  for (let blockIndex = 0; blockIndex < blockCount; blockIndex += 1) {
    boundaries.push(entry.offset + readU32(bytes, entry.offset + blockIndex * 4));
  }
  boundaries.push(entry.offset + entry.compressedSize);

  const minimumBlockOffset = entry.offset + blockCount * 4;
  for (let blockIndex = 0; blockIndex < blockCount; blockIndex += 1) {
    const start = boundaries[blockIndex];
    const end = boundaries[blockIndex + 1];
    if (start < minimumBlockOffset || end < start || end > entry.offset + entry.compressedSize) {
      throw new Error('invalid archive');
    }
  }

  const output = new Uint8Array(entry.size);
  let outputOffset = 0;
  for (let blockIndex = 0; blockIndex < blockCount; blockIndex += 1) {
    const decoded = decodeLzf(bytes.subarray(boundaries[blockIndex], boundaries[blockIndex + 1]), BLOCK_SIZE);
    if (outputOffset + decoded.length > output.length) {
      throw new Error('invalid archive');
    }
    output.set(decoded, outputOffset);
    outputOffset += decoded.length;
  }
  if (outputOffset !== entry.size) {
    throw new Error('invalid archive');
  }
  return output;
}

function validateSwf(bytes) {
  requireRange(bytes, 0, 8);
  const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2]);
  if (magic !== 'CWS' && magic !== 'FWS') {
    throw new Error('invalid archive');
  }
  const declaredSize = readU32(bytes, 4);
  if (declaredSize < 1024 * 1024) {
    throw new Error('invalid archive');
  }
}

function run(argv) {
  const inputPath = $(argv[0]).stringByStandardizingPath;
  const outputPath = $(argv[1]).stringByStandardizingPath;
  const data = $.NSData.dataWithContentsOfFile(inputPath);
  if (!data) {
    throw new Error('invalid archive');
  }

  const sourceLength = Number(data.length);
  const sourceBytes = $.NSData.dataWithBytesLength(data.bytes, sourceLength);
  const sourceText = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(sourceBytes, $.NSISOLatin1StringEncoding));
  if (sourceText === null || sourceText.length !== sourceLength) {
    throw new Error('invalid archive');
  }
  const source = new Uint8Array(sourceLength);
  for (let index = 0; index < sourceLength; index += 1) {
    source[index] = sourceText.charCodeAt(index);
  }

  const parsed = parseEntries(source);
  const extracted = extractEntry(source, parsed.entry, parsed.tableOffset);
  validateSwf(extracted);

  const output = $.NSMutableData.dataWithLength(extracted.length);
  const outputBytes = output.mutableBytes;
  for (let index = 0; index < extracted.length; index += 1) {
    outputBytes[index] = extracted[index];
  }
  if (!output.writeToFileAtomically(outputPath, true)) {
    throw new Error('cannot write output');
  }
}
JXA
}

show_install_progress() {
  local dots=''
  while true; do
    dots+='.'
    (( ${#dots} > 3 )) && dots=''
    print -n -- "\r한국어 글꼴 설치 중${dots}   "
    /bin/sleep 0.4
  done
}

run_extractor_with_progress() {
  local spinner_pid
  local exit_code=1

  show_install_progress &
  spinner_pid=$!
  {
    run_extractor "$@"
    exit_code=$?
  } always {
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    print -n -- $'\r\e[K'
  }
  return "$exit_code"
}

write_fonts_csv() {
  local output="$1"
  /usr/bin/osascript -l JavaScript - "$output" 2>/dev/null <<'JXA'
function run(argv) {
  ObjC.import('Foundation');
  const text = 'FontAlias;FontName;FontName_ZH;FontName_JP;FontName_KR\n' +
    'Font_Style_Standard;NanumGothic Bold;PMingLiU;YOzFontM90;NanumGothic Bold\n' +
    'Font_Style_Black;NanumGothic Bold;PMingLiU;YOzFontM90;NanumGothic Bold\n';
  const body = $(text).dataUsingEncoding($.NSUTF16LittleEndianStringEncoding);
  const data = $.NSMutableData.dataWithLength(2);
  const bytes = data.mutableBytes;
  bytes[0] = 0xFF;
  bytes[1] = 0xFE;
  data.appendData(body);
  if (!data.writeToFileAtomically($(argv[0]).stringByStandardizingPath, true)) {
    throw new Error('cannot write output');
  }
}
JXA
}

is_game_dir() {
  local dir="$1"
  test -f "$dir/$SOURCE_ARCHIVE_REL" && test -d "$dir/The Witcher 2.app"
}

collect_game_dirs() {
  local steam_root="$HOME/Library/Application Support/Steam"
  local vdf="$steam_root/steamapps/libraryfolders.vdf"
  local library candidate
  local -a libraries
  local -A seen

  libraries=("$steam_root")
  if [[ -f "$vdf" ]]; then
    while IFS= read -r library; do
      [[ -n "$library" ]] && libraries+=("$library")
    done < <(/usr/bin/sed -nE 's/^[[:space:]]*"path"[[:space:]]*"([^"]*)".*/\1/p' "$vdf")
  fi

  for library in "${libraries[@]}"; do
    candidate="$library/steamapps/common/the witcher 2"
    if is_game_dir "$candidate"; then
      candidate="${candidate:A}"
      if [[ -z "${seen[$candidate]:-}" ]]; then
        seen[$candidate]=1
        print -r -- "$candidate"
      fi
    fi
  done
}

resolve_game_dir() {
  local input selected
  local -a game_dirs
  game_dirs=("${(@f)$(collect_game_dirs)}")

  if (( ${#game_dirs[@]} == 1 )); then
    print -r -- "$game_dirs[1]"
    return 0
  fi

  if (( ${#game_dirs[@]} > 1 )); then
    local index=1
    print -u2 -- '여러 Steam 설치를 찾았습니다:'
    for selected in "${game_dirs[@]}"; do
      print -u2 -- "$index. $selected"
      (( index += 1 ))
    done
    print -u2 -n -- '번호를 선택하거나 게임 폴더를 드래그하세요: '
  else
    print -u2 -n -- '게임 폴더를 Terminal로 드래그하세요: '
  fi

  read -r input || return 1
  input="${(Q)input}"
  if [[ "$input" == <-> ]] && (( ${#game_dirs[@]} > 1 )) && (( input >= 1 && input <= ${#game_dirs[@]} )); then
    print -r -- "$game_dirs[$input]"
    return 0
  fi
  if is_game_dir "$input"; then
    print -r -- "${input:A}"
    return 0
  fi
  die '유효한 The Witcher 2 Steam 게임 폴더가 아닙니다.'
}

ensure_game_is_not_running() {
  local game_dir="$1"
  local executable="$game_dir/The Witcher 2.app/Contents/MacOS/The Witcher 2"
  local process_commands
  process_commands="$(/bin/ps -ax -o command=)" || {
    die '게임 실행 상태를 확인할 수 없어 이 작업을 수행하지 않습니다.'
    return 1
  }
  if [[ "$process_commands" == *"$executable"* ]]; then
    die '게임이 실행 중이므로 이 작업을 수행할 수 없습니다.'
    return 1
  fi
}

install_patch() {
  local game_dir="$1"
  local target_swf="$game_dir/$PATCH_FONT_REL"
  local target_csv="$game_dir/$PATCH_CSV_REL"

  ensure_game_is_not_running "$game_dir" || return 1
  /bin/mkdir -p "${target_csv:h}" || {
    die '패치 폴더를 만들지 못했습니다.'
    return 1
  }

  run_extractor_with_progress "$game_dir/$SOURCE_ARCHIVE_REL" "$target_swf" || {
    die '한국어 글꼴을 준비하지 못했습니다.'
    print -u2 -- 'Steam 무결성 검사를 실행한 뒤 다시 시도해 주세요.'
    return 1
  }

  write_fonts_csv "$target_csv" || {
    die '글꼴 설정 파일을 만들지 못했습니다. 패처를 다시 실행해 주세요.'
    return 1
  }
}

uninstall_patch() {
  local game_dir="$1"
  local target_swf="$game_dir/$PATCH_FONT_REL"
  local target_csv="$game_dir/$PATCH_CSV_REL"
  local fonts_dir="${target_csv:h}"

  ensure_game_is_not_running "$game_dir" || return 1
  /bin/rm -f -- "$target_swf" "$target_csv" || {
    die '패치 파일을 제거하지 못했습니다.'
    return 1
  }
  /bin/rmdir "$fonts_dir" 2>/dev/null || true
}

show_menu() {
  print -r -- '1. 패치 설치/업데이트'
  print -r -- '2. 패치 제거'
  print -r -- '3. 현재 상태 확인'
  print -r -- '4. 종료'
}

show_status() {
  local game_dir="$1"
  local target_swf="$game_dir/$PATCH_FONT_REL"
  local target_csv="$game_dir/$PATCH_CSV_REL"
  local user_ini
  if [[ -f "$target_swf" && -f "$target_csv" ]]; then
    print -r -- '현재 패치 상태: 설치됨'
  else
    print -r -- '현재 패치 상태: 설치 필요'
  fi
  user_ini="$HOME/Library/Application Support/com.cdprojektred.TheWitcher2/GameDocuments/Witcher 2/config/User.ini"
  if [[ -f "$user_ini" ]]; then
    if /usr/bin/grep -Eq '^[[:space:]]*Language[[:space:]]*=[[:space:]]*KR[[:space:]]*$' "$user_ini"; then
      print -r -- '한국어 설정(Language=KR)을 확인했습니다.'
    else
      print -u2 -- '경고: User.ini에서 Language=KR을 찾지 못했습니다.'
    fi
  else
    print -u2 -- '경고: User.ini를 찾지 못했습니다.'
  fi
}

confirm_mutation() {
  local game_dir="$1"
  local answer
  print -r -- "감지된 게임 경로: $game_dir"
  print -r -- "대상 fonts.swf: $game_dir/$PATCH_FONT_REL"
  print -r -- "대상 fonts.csv: $game_dir/$PATCH_CSV_REL"
  print -n -- '계속하시겠습니까? [y/N] '
  read -r answer || return 1
  [[ "$answer" == y || "$answer" == Y ]]
}

main() {
  local choice game_dir=''

  while true; do
    show_menu
    print -n -- '선택: '
    read -r choice || return 0
    case "$choice" in
      1|2|3)
        if [[ -z "$game_dir" ]]; then
          game_dir="$(resolve_game_dir)" || continue
        fi
        if [[ "$choice" == 1 ]]; then
          confirm_mutation "$game_dir" || {
            print -r -- '취소했습니다.'
            continue
          }
          install_patch "$game_dir" && print -r -- '패치를 설치했습니다.'
        elif [[ "$choice" == 2 ]]; then
          confirm_mutation "$game_dir" || {
            print -r -- '취소했습니다.'
            continue
          }
          uninstall_patch "$game_dir" && print -r -- '패치를 제거했습니다.'
        else
          print -r -- "감지된 게임 경로: $game_dir"
          show_status "$game_dir"
        fi
        ;;
      4)
        return 0
        ;;
      *)
        print -u2 -- '1부터 4 사이의 번호를 입력하세요.'
        ;;
    esac
  done
}

if [[ "${W2KFF_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
