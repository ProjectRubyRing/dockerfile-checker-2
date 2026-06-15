#!/usr/bin/env bash
# Static checker for Dockerfile, build context resources, entrypoint scripts,
# WildFly jboss-cli CLI files, and UBI 9.6 runtime consistency.

set -o pipefail

VERSION="0.1.0"

CONTEXT_DIR="."
DOCKERFILE_PATH=""
ENTRYPOINT_OVERRIDE=""
FAIL_ON="error"
INCLUDE_UNUSED_ALL=0
NO_COLOR=0
PROGRESS=1
REPORT_ENABLED=1
REPORT_FILE=""

declare -a F_SEV=()
declare -a F_PHASE=()
declare -a F_FILE=()
declare -a F_LINE=()
declare -a F_CODE=()
declare -a F_MSG=()
declare -A F_COUNT=([ERROR]=0 [WARN]=0 [INFO]=0)

declare -a DF_INSTR=()
declare -a DF_BODY=()
declare -a DF_START=()
declare -a DF_END=()
declare -a DF_STAGE=()

declare -a STAGE_NAME=()
declare -a STAGE_BASE=()
declare -a STAGE_LINE=()
declare -a STAGE_WORKDIR_FINAL=()
declare -A STAGE_BY_NAME=()

declare -A DOCKER_ENV=()
declare -A DOCKER_ENV_LINE=()
declare -A DOCKER_ARG=()
declare -A DOCKER_ARG_LINE=()
declare -A DOCKER_VAR_USED=()

declare -A DOCKERIGNORE_PATTERNS=()
declare -a DOCKERIGNORE_ORDER=()
declare -A REFERENCED_CONTEXT=()
declare -A CONTEXT_SYMLINK_SEEN=()
declare -A CONTAINER_TO_CONTEXT=()
declare -A SHELL_FILES=()
declare -A SHELL_REASON=()
declare -A CLI_FILES=()
declare -A CLI_REASON=()
declare -A CLI_JNDI_SEEN=()
declare -A MISSING_PATH_SEEN=()

FINAL_STAGE=-1
FINAL_BASE=""
FINAL_WORKDIR="/"
FINAL_USER=""
FINAL_USER_LINE=0
FINAL_ENTRYPOINT_BODY=""
FINAL_ENTRYPOINT_LINE=0
FINAL_CMD_BODY=""
FINAL_CMD_LINE=0
FINAL_IS_UBI9=0
FINAL_IS_UBI96=0
FINAL_IS_UBI_MINIMAL=0
FINAL_INSTALLS_BASH=0

usage() {
  cat <<'USAGE'
docker-context-checker.sh - Dockerfile / build context static checker

Usage:
  ./docker-context-checker.sh [options]

Options:
  -c, --context DIR        Build context directory. Default: current directory.
  -f, --dockerfile FILE    Dockerfile path. Default: <context>/Dockerfile.
  -e, --entrypoint FILE    Entrypoint shell file in the build context to scan
                           when it cannot be resolved from Dockerfile.
  -o, --output FILE        Write Excel-importable UTF-8 BOM CSV report.
                           Default: ./docker-context-checker-results.csv.
      --include-unused-all Report every unreferenced file in the build context.
      --fail-on LEVEL      error, warn, or never. Default: error.
      --no-progress        Do not print phase-by-phase progress messages.
      --no-output          Do not write the CSV report file.
      --no-color           Disable ANSI colors.
  -h, --help               Show this help.
      --version            Show version.

Checks include:
  - Dockerfile FROM / multi-stage / COPY --from validation.
  - COPY and ADD source existence, .dockerignore exclusion, and context symlink health.
  - Symlink creation phase: Dockerfile RUN is build phase; entrypoint/called scripts
    are runtime phase.
  - Entrypoint and called shell variable checks: unused, empty initialization,
    use-before-init, required external values, and values without defaults.
  - WildFly jboss-cli --file / --commands detection, CLI file syntax heuristics,
    and JNDI setting validation.
  - UBI 9.6 final image consistency, especially runtime entrypoint behavior.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    local d b
    d=$(dirname -- "$p")
    b=$(basename -- "$p")
    (cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b") || printf '%s\n' "$p"
  fi
}

rel_to_context() {
  local p abs
  p="$1"
  abs=$(abs_path "$p")
  if [[ "$abs" == "$CONTEXT_DIR" ]]; then
    printf '.'
  elif [[ "$abs" == "$CONTEXT_DIR/"* ]]; then
    printf '%s' "${abs#"$CONTEXT_DIR/"}"
  else
    printf '%s' "$abs"
  fi
}

display_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf '-'
    return
  fi
  if [[ "$p" == "$CONTEXT_DIR/"* || "$p" == "$CONTEXT_DIR" ]]; then
    rel_to_context "$p"
  else
    printf '%s' "$p"
  fi
}

progress_log() {
  local step="$1" msg="$2"
  (( PROGRESS )) || return 0
  printf '[%s] %-12s %s (ERROR=%s WARN=%s INFO=%s)\n' \
    "$(date '+%H:%M:%S')" "$step" "$msg" \
    "${F_COUNT[ERROR]:-0}" "${F_COUNT[WARN]:-0}" "${F_COUNT[INFO]:-0}" >&2
}

add_finding() {
  local sev="$1" phase="$2" file="$3" line="$4" code="$5" msg="$6"
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  F_SEV+=("$sev")
  F_PHASE+=("$phase")
  F_FILE+=("$file")
  F_LINE+=("$line")
  F_CODE+=("$code")
  F_MSG+=("$msg")
  F_COUNT[$sev]=$(( ${F_COUNT[$sev]:-0} + 1 ))
}

parse_args() {
  while (($#)); do
    case "$1" in
      -c|--context)
        [[ $# -ge 2 ]] || die "$1 requires a directory"
        CONTEXT_DIR="$2"
        shift 2
        ;;
      -f|--dockerfile)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        DOCKERFILE_PATH="$2"
        shift 2
        ;;
      -e|--entrypoint)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        ENTRYPOINT_OVERRIDE="$2"
        shift 2
        ;;
      -o|--output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        REPORT_FILE="$2"
        REPORT_ENABLED=1
        shift 2
        ;;
      --include-unused-all)
        INCLUDE_UNUSED_ALL=1
        shift
        ;;
      --fail-on)
        [[ $# -ge 2 ]] || die "$1 requires error, warn, or never"
        FAIL_ON="$2"
        shift 2
        ;;
      --no-color)
        NO_COLOR=1
        shift
        ;;
      --no-progress)
        PROGRESS=0
        shift
        ;;
      --no-output)
        REPORT_ENABLED=0
        shift
        ;;
      --version)
        printf '%s\n' "$VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  case "$FAIL_ON" in
    error|warn|never) ;;
    *) die "--fail-on must be error, warn, or never" ;;
  esac
}

load_dockerignore() {
  local file="$CONTEXT_DIR/.dockerignore"
  [[ -f "$file" ]] || return 0

  local line no=0 pattern
  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    pattern="$(trim "$line")"
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    DOCKERIGNORE_PATTERNS["$no"]="$pattern"
    DOCKERIGNORE_ORDER+=("$no")
  done < "$file"
}

matches_dockerignore_pattern() {
  local rel="$1" pattern="$2"
  local basename_rel="${rel##*/}"
  pattern="${pattern#./}"
  pattern="${pattern%/}"
  [[ -z "$pattern" ]] && return 1

  if [[ "$pattern" == *"/"* ]]; then
    [[ "$rel" == $pattern || "$rel" == $pattern/* ]]
  else
    [[ "$basename_rel" == $pattern || "$rel" == */$pattern || "$rel" == $pattern ]]
  fi
}

is_dockerignored() {
  local rel="$1" ignored=1 id pattern neg
  rel="${rel#./}"
  for id in "${DOCKERIGNORE_ORDER[@]}"; do
    pattern="${DOCKERIGNORE_PATTERNS[$id]}"
    neg=0
    if [[ "$pattern" == !* ]]; then
      neg=1
      pattern="${pattern#!}"
    fi
    if matches_dockerignore_pattern "$rel" "$pattern"; then
      if ((neg)); then
        ignored=1
      else
        ignored=0
      fi
    fi
  done
  (( ignored == 0 ))
}

process_dockerfile_instruction() {
  local raw="$1" start="$2" end="$3" logical instr body idx upper current_stage
  logical=$(printf '%s\n' "$raw" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\[[:space:]]*\n/ /g')
  logical="$(trim "$logical")"
  [[ -z "$logical" || "$logical" == \#* ]] && return 0

  instr="${logical%%[[:space:]]*}"
  upper=$(printf '%s' "$instr" | tr '[:lower:]' '[:upper:]')
  body="${logical#"$instr"}"
  body="$(trim "$body")"

  if [[ "$upper" == "FROM" ]]; then
    parse_from_instruction "$body" "$start"
  fi

  current_stage="$FINAL_STAGE"
  idx="${#DF_INSTR[@]}"
  DF_INSTR[$idx]="$upper"
  DF_BODY[$idx]="$body"
  DF_START[$idx]="$start"
  DF_END[$idx]="$end"
  DF_STAGE[$idx]="$current_stage"
}

parse_from_instruction() {
  local body="$1" line="$2"
  local -a words=()
  local image="" stage_name="" i word lower_word
  # shellcheck disable=SC2206
  words=($body)

  for ((i=0; i<${#words[@]}; i++)); do
    word="${words[$i]}"
    [[ "$word" == --* ]] && continue
    image="$word"
    break
  done

  if [[ -z "$image" ]]; then
    FINAL_STAGE=$((FINAL_STAGE + 1))
    STAGE_BASE[$FINAL_STAGE]=""
    STAGE_NAME[$FINAL_STAGE]=""
    STAGE_LINE[$FINAL_STAGE]="$line"
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF001" "FROM instruction has no base image."
    return 0
  fi

  for ((; i<${#words[@]}; i++)); do
    lower_word="$(lower "${words[$i]}")"
    if [[ "$lower_word" == "as" && $((i + 1)) -lt ${#words[@]} ]]; then
      stage_name="${words[$((i + 1))]}"
      break
    fi
  done

  FINAL_STAGE=$((FINAL_STAGE + 1))
  STAGE_BASE[$FINAL_STAGE]="$image"
  STAGE_NAME[$FINAL_STAGE]="$stage_name"
  STAGE_LINE[$FINAL_STAGE]="$line"
  STAGE_WORKDIR_FINAL[$FINAL_STAGE]="/"

  if [[ -n "$stage_name" ]]; then
    local key
    key="$(lower "$stage_name")"
    if [[ -n "${STAGE_BY_NAME[$key]:-}" ]]; then
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF002" "Duplicate multi-stage name '$stage_name'."
    else
      STAGE_BY_NAME[$key]="$FINAL_STAGE"
    fi
  fi
}

parse_dockerfile() {
  local line no=0 combined="" start=0 trimmed_line
  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    if [[ -z "$combined" ]]; then
      start="$no"
      combined="$line"
    else
      combined+=$'\n'"$line"
    fi
    trimmed_line="${line%"${line##*[![:space:]]}"}"
    if [[ "$trimmed_line" == *\\ && ! "$trimmed_line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    process_dockerfile_instruction "$combined" "$start" "$no"
    combined=""
  done < "$DOCKERFILE_PATH"

  if [[ -n "$combined" ]]; then
    process_dockerfile_instruction "$combined" "$start" "$no"
  fi

  if (( FINAL_STAGE < 0 )); then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "1" "DF003" "Dockerfile has no FROM instruction."
  fi
}

json_array_tokens() {
  awk '
  {
    in_string=0; esc=0; token="";
    for (i=1; i<=length($0); i++) {
      c=substr($0,i,1);
      if (in_string) {
        if (esc) { token=token c; esc=0; }
        else if (c=="\\") { esc=1; }
        else if (c=="\"") { print token; token=""; in_string=0; }
        else { token=token c; }
      } else if (c=="\"") {
        in_string=1;
      }
    }
  }'
}

normalize_context_source() {
  local src="$1"
  src="${src#./}"
  while [[ "$src" == /* ]]; do
    src="${src#/}"
  done
  printf '%s' "$src"
}

normalize_container_path() {
  local path="$1"
  printf '%s\n' "$path" | awk '
  BEGIN { FS="/"; OFS="/"; }
  {
    abs = ($0 ~ /^\//);
    n = split($0, part, "/");
    out_n = 0;
    for (i=1; i<=n; i++) {
      if (part[i] == "" || part[i] == ".") continue;
      if (part[i] == "..") {
        if (out_n > 0) out_n--;
        continue;
      }
      out[++out_n] = part[i];
    }
    if (abs) printf "/";
    for (i=1; i<=out_n; i++) {
      printf "%s", out[i];
      if (i < out_n) printf "/";
    }
    if (out_n == 0 && !abs) printf ".";
    printf "\n";
  }'
}

container_abs_path() {
  local workdir="$1" path="$2"
  if [[ "$path" == /* ]]; then
    normalize_container_path "$path"
  else
    normalize_container_path "$workdir/$path"
  fi
}

is_url() {
  [[ "$1" =~ ^https?:// || "$1" =~ ^ftp:// ]]
}

is_relevant_context_file() {
  local rel="$1"
  case "$rel" in
    Dockerfile|.dockerignore|README.md|docker-context-checker.sh|.gitattributes) return 1 ;;
    .git/*) return 1 ;;
  esac
  if (( INCLUDE_UNUSED_ALL )); then
    return 0
  fi
  case "$(lower "$rel")" in
    *.sh|*.bash|*.ksh|*.cli|*.xml|*.properties|*.conf|*.cfg|*.json|*.yaml|*.yml|*.war|*.ear|*.jar|*.pem|*.crt|*.key|*.sql)
      return 0
      ;;
  esac
  return 1
}

record_context_symlink() {
  local full="$1" rel target abs_target
  [[ -L "$full" ]] || return 0
  rel="$(rel_to_context "$full")"
  [[ -n "${CONTEXT_SYMLINK_SEEN[$rel]:-}" ]] && return 0
  CONTEXT_SYMLINK_SEEN[$rel]=1
  target="$(readlink "$full" 2>/dev/null || true)"
  if [[ ! -e "$full" ]]; then
    add_finding "ERROR" "build-context" "$full" "-" "CTX004" "Build context symlink '$rel' is broken; target is '$target'."
    return 0
  fi
  if [[ "$target" == /* ]]; then
    abs_target="$(abs_path "$target")"
  else
    abs_target="$(abs_path "$(dirname "$full")/$target")"
  fi
  if [[ "$abs_target" != "$CONTEXT_DIR/"* && "$abs_target" != "$CONTEXT_DIR" ]]; then
    add_finding "WARN" "build-context" "$full" "-" "CTX005" "Build context symlink '$rel' points outside the build context: $target"
  else
    add_finding "INFO" "build-context" "$full" "-" "CTX006" "Build context symlink '$rel' is provided by the host context before docker build; target: $target"
  fi
}

mark_context_path_referenced() {
  local full="$1" rel child
  record_context_symlink "$full"
  if [[ -d "$full" && ! -L "$full" ]]; then
    while IFS= read -r -d '' child; do
      rel="$(rel_to_context "$child")"
      REFERENCED_CONTEXT["$rel"]=1
      record_context_symlink "$child"
    done < <(find "$full" -path '*/.git' -prune -o -type f -print0 -o -type l -print0)
  else
    rel="$(rel_to_context "$full")"
    REFERENCED_CONTEXT["$rel"]=1
  fi
}

map_container_to_context_for_path() {
  local full="$1" src_rel="$2" dest="$3" src_count="$4" workdir="$5"
  local src_abs dest_abs dest_is_dir rel basename child child_rel inside cpath dest_base
  src_abs="$(abs_path "$full")"
  dest_abs="$(container_abs_path "$workdir" "$dest")"
  dest_is_dir=0
  [[ "$dest" == */ || "$src_count" -gt 1 ]] && dest_is_dir=1

  if [[ -d "$src_abs" && ! -L "$src_abs" ]]; then
    dest_base="$dest_abs"
    while IFS= read -r -d '' child; do
      child_rel="$(rel_to_context "$child")"
      inside="${child_rel#"$src_rel"/}"
      [[ "$inside" == "$child_rel" ]] && inside="${child_rel##*/}"
      cpath="$(normalize_container_path "$dest_base/$inside")"
      CONTAINER_TO_CONTEXT["$cpath"]="$child_rel"
      cpath="$(normalize_container_path "$dest_base/$(basename -- "$src_rel")/$inside")"
      CONTAINER_TO_CONTEXT["$cpath"]="$child_rel"
    done < <(find "$src_abs" -type f -print0 -o -type l -print0)
  else
    rel="$(rel_to_context "$src_abs")"
    basename="$(basename -- "$src_rel")"
    if (( dest_is_dir )); then
      cpath="$(normalize_container_path "$dest_abs/$basename")"
    else
      cpath="$dest_abs"
    fi
    CONTAINER_TO_CONTEXT["$cpath"]="$rel"
  fi
}

resolve_context_matches() {
  local src="$1" line="$2" inst="$3"
  local norm pattern full rel
  norm="$(normalize_context_source "$src")"
  if [[ "$norm" == *'$'* ]]; then
    add_finding "WARN" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX001" "$inst source '$src' contains a variable; static context existence cannot be fully resolved."
    return 0
  fi
  if [[ "$norm" == .. || "$norm" == ../* || "$norm" == */../* ]]; then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX002" "$inst source '$src' attempts to escape the build context."
    return 0
  fi
  if is_dockerignored "$norm"; then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX003" "$inst source '$src' is excluded by .dockerignore."
  fi

  if [[ "$norm" == *[\*\?\[]* ]]; then
    shopt -s nullglob globstar
    local -a matches=()
    mapfile -t matches < <(compgen -G "$CONTEXT_DIR/$norm" || true)
    shopt -u nullglob globstar
    if (( ${#matches[@]} == 0 )); then
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX007" "$inst source glob '$src' matches no build context files."
      return 0
    fi
    printf '%s\n' "${matches[@]}"
    return 0
  fi

  full="$CONTEXT_DIR/$norm"
  if [[ -e "$full" || -L "$full" ]]; then
    printf '%s\n' "$full"
  else
    rel="$norm"
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX008" "$inst source '$rel' does not exist in the build context."
  fi
}

validate_copy_from_reference() {
  local ref="$1" line="$2"
  local ref_l="$ref"
  ref_l="$(lower "$ref_l")"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    if (( ref < 0 || ref > FINAL_STAGE )); then
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF004" "COPY --from=$ref references a stage index that does not exist."
    fi
    return 0
  fi
  if [[ -n "${STAGE_BY_NAME[$ref_l]:-}" ]]; then
    return 0
  fi
  if [[ "$ref" == *"/"* || "$ref" == *":"* || "$ref" == *"."* ]]; then
    add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF005" "COPY --from=$ref is treated as an external image, not a build-context resource."
  else
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF006" "COPY --from=$ref does not match any multi-stage alias or numeric stage."
  fi
}

parse_copy_add_instruction() {
  local inst="$1" body="$2" line="$3" stage="$4" workdir="$5"
  local prefix json_part word from="" skip_next=0 link=0
  local -a tokens=() operands=() sources=() matches=()
  local dest src full src_rel i

  # shellcheck disable=SC2206
  local -a raw_words=($body)
  for ((i=0; i<${#raw_words[@]}; i++)); do
    word="${raw_words[$i]}"
    if ((skip_next)); then
      skip_next=0
      continue
    fi
    case "$word" in
      --from=*) from="${word#--from=}" ;;
      --from) [[ $((i + 1)) -lt ${#raw_words[@]} ]] && from="${raw_words[$((i + 1))]}" && skip_next=1 ;;
      --link) link=1 ;;
    esac
  done
  [[ -n "$from" ]] && validate_copy_from_reference "$from" "$line"
  (( link )) && add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF007" "$inst uses --link; verify the target builder/runtime supports BuildKit link layer semantics."

  if [[ "$(trim "$body")" == *"["* ]]; then
    prefix="${body%%[*}"
    json_part="[${body#*[}"
    mapfile -t tokens < <(printf '%s\n' "$json_part" | json_array_tokens)
  else
    for word in "${raw_words[@]}"; do
      if ((skip_next)); then
        skip_next=0
        continue
      fi
      case "$word" in
        --from=*) continue ;;
        --from) skip_next=1; continue ;;
        --chown=*|--chmod=*|--link|--parents|--exclude=*) continue ;;
        --*) continue ;;
        *) tokens+=("${word%$'\r'}") ;;
      esac
    done
  fi

  if (( ${#tokens[@]} < 2 )); then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF008" "$inst has fewer than one source and one destination."
    return 0
  fi

  dest="${tokens[$((${#tokens[@]} - 1))]}"
  sources=("${tokens[@]:0:$((${#tokens[@]} - 1))}")

  if [[ -n "$from" ]]; then
    return 0
  fi

  for src in "${sources[@]}"; do
    if [[ "$inst" == "ADD" ]] && is_url "$src"; then
      add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX009" "ADD downloads remote resource '$src'; static build-context checks do not apply."
      continue
    fi
    mapfile -t matches < <(resolve_context_matches "$src" "$line" "$inst")
    for full in "${matches[@]}"; do
      [[ -z "$full" ]] && continue
      src_rel="$(rel_to_context "$full")"
      mark_context_path_referenced "$full"
      map_container_to_context_for_path "$full" "$src_rel" "$dest" "${#sources[@]}" "$workdir"
    done
  done
}

extract_var_refs() {
  awk '
  {
    s=$0
    for (i=1; i<=length(s); i++) {
      c=substr(s,i,1)
      if (c != "$") continue
      if (i > 1 && substr(s,i-1,1) == "\\") continue
      n=substr(s,i+1,1)
      if (n == "{") {
        j=i+2; expr=""
        while (j<=length(s) && substr(s,j,1)!="}") {
          expr=expr substr(s,j,1); j++
        }
        if (j>length(s)) continue
        if (substr(expr,1,1) == "!") expr=substr(expr,2)
        if (match(expr, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          var=substr(expr,RSTART,RLENGTH)
          rest=substr(expr,RLENGTH+1)
          kind="plain"
          if (rest ~ /^:-/ || rest ~ /^-/ || rest ~ /^:=/ || rest ~ /^=/) kind="default"
          else if (rest ~ /^:\?/ || rest ~ /^\?/) kind="required"
          else if (rest ~ /^:\+/ || rest ~ /^\+/) kind="alternate"
          print var "|" kind
        }
        i=j
      } else if (n ~ /[A-Za-z_]/) {
        j=i+1; var=""
        while (j<=length(s) && substr(s,j,1) ~ /[A-Za-z0-9_]/) {
          var=var substr(s,j,1); j++
        }
        print var "|plain"
        i=j-1
      }
    }
  }'
}

is_standard_env_var() {
  case "$1" in
    PATH|HOME|PWD|OLDPWD|SHELL|USER|LOGNAME|HOSTNAME|LANG|LC_ALL|TERM|TMPDIR|TZ|UID|EUID|BASH|BASH_SOURCE|BASH_VERSION|LINENO|RANDOM|SECONDS|IFS|OPTIND|OPTARG|JAVA_HOME|JBOSS_HOME|WILDFLY_HOME|LAUNCH_JBOSS_IN_BACKGROUND)
      return 0
      ;;
  esac
  return 1
}

parse_env_instruction() {
  local body="$1" line="$2"
  local -a words=()
  local word key value
  # shellcheck disable=SC2206
  words=($body)
  if (( ${#words[@]} == 0 )); then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR001" "ENV has no key/value."
    return 0
  fi
  if [[ "${words[0]}" != *=* ]]; then
    if (( ${#words[@]} >= 2 )); then
      key="${words[0]}"
      value="${words[*]:1}"
      DOCKER_ENV["$key"]="$value"
      DOCKER_ENV_LINE["$key"]="$line"
      add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR002" "ENV uses legacy 'key value' form; prefer key=value for predictable parsing."
    else
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR003" "ENV '$body' has no value."
    fi
    return 0
  fi
  for word in "${words[@]}"; do
    key="${word%%=*}"
    value="${word#*=}"
    DOCKER_ENV["$key"]="$value"
    DOCKER_ENV_LINE["$key"]="$line"
    if [[ -z "$value" || "$value" == '""' || "$value" == "''" ]]; then
      add_finding "WARN" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR004" "ENV '$key' is initialized as empty."
    fi
  done
}

parse_arg_instruction() {
  local body="$1" line="$2" part key value
  part="$(trim "$body")"
  key="${part%%=*}"
  value=""
  [[ "$part" == *=* ]] && value="${part#*=}"
  if [[ -z "$key" ]]; then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR005" "ARG has no name."
    return 0
  fi
  DOCKER_ARG["$key"]="$value"
  DOCKER_ARG_LINE["$key"]="$line"
  if [[ "$part" != *=* ]]; then
    add_finding "WARN" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR006" "ARG '$key' has no default; it must be supplied by build-arg if required."
  fi
}

scan_dockerfile_var_use() {
  local text="$1" line="$2" phase="$3"
  local use var kind
  while IFS= read -r use; do
    [[ -z "$use" ]] && continue
    var="${use%%|*}"
    kind="${use#*|}"
    DOCKER_VAR_USED["$var"]=1
    if [[ "$kind" == "required" ]]; then
      add_finding "WARN" "$phase" "$DOCKERFILE_PATH" "$line" "VAR007" "Dockerfile variable '$var' is required via parameter expansion."
    elif [[ "$kind" == "plain" || "$kind" == "alternate" ]]; then
      if [[ -z "${DOCKER_ENV[$var]:-}" && -z "${DOCKER_ARG[$var]:-}" ]] && ! is_standard_env_var "$var"; then
        add_finding "WARN" "$phase" "$DOCKERFILE_PATH" "$line" "VAR008" "Dockerfile uses variable '$var' without an ARG/ENV definition or default."
      fi
    fi
  done < <(printf '%s\n' "$text" | extract_var_refs)
}

detect_symlink_command() {
  local text="$1"
  local re='(^|[[:space:];|&])ln[[:space:]][^#;|&]*-[A-Za-z]*s'
  [[ "$text" =~ $re ]]
}

find_context_by_basename() {
  local name="$1"
  find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f -name "$name" -print | head -n 1
}

add_shell_file() {
  local rel="$1" reason="$2"
  [[ -z "$rel" ]] && return 0
  rel="${rel#./}"
  [[ -n "${SHELL_FILES[$rel]:-}" ]] && return 0
  SHELL_FILES["$rel"]=1
  SHELL_REASON["$rel"]="$reason"
}

add_cli_file() {
  local rel="$1" reason="$2"
  [[ -z "$rel" ]] && return 0
  rel="${rel#./}"
  [[ -n "${CLI_FILES[$rel]:-}" ]] && return 0
  CLI_FILES["$rel"]=1
  CLI_REASON["$rel"]="$reason"
}

resolve_script_reference() {
  local token="$1" current_rel="$2" line="$3" phase="$4" workdir="$5"
  local cleaned="$token" full rel cpath bybase
  cleaned="${cleaned%\"}"
  cleaned="${cleaned#\"}"
  cleaned="${cleaned%\'}"
  cleaned="${cleaned#\'}"
  cleaned="${cleaned%;}"
  cleaned="${cleaned%%#*}"
  cleaned="${cleaned%%\?*}"
  cleaned="${cleaned%%:*}"
  [[ -z "$cleaned" || "$cleaned" == *'$'* || "$cleaned" == *'*'* ]] && return 1

  if [[ "$cleaned" == /* ]]; then
    cpath="$(normalize_container_path "$cleaned")"
    if [[ -n "${CONTAINER_TO_CONTEXT[$cpath]:-}" ]]; then
      printf '%s\n' "${CONTAINER_TO_CONTEXT[$cpath]}"
      return 0
    fi
    bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
    if [[ -n "$bybase" ]]; then
      rel="$(rel_to_context "$bybase")"
      add_finding "INFO" "$phase" "$DOCKERFILE_PATH" "$line" "SH001" "Resolved '$cleaned' by basename to '$rel'; verify container path mapping."
      printf '%s\n' "$rel"
      return 0
    fi
    return 1
  fi

  if [[ -n "$current_rel" ]]; then
    full="$CONTEXT_DIR/$(dirname "$current_rel")/$cleaned"
    if [[ -f "$full" || -L "$full" ]]; then
      rel="$(rel_to_context "$full")"
      printf '%s\n' "$rel"
      return 0
    fi
  fi

  full="$CONTEXT_DIR/$cleaned"
  if [[ -f "$full" || -L "$full" ]]; then
    rel="$(rel_to_context "$full")"
    printf '%s\n' "$rel"
    return 0
  fi

  if [[ -n "$workdir" ]]; then
    cpath="$(container_abs_path "$workdir" "$cleaned")"
    if [[ -n "${CONTAINER_TO_CONTEXT[$cpath]:-}" ]]; then
      printf '%s\n' "${CONTAINER_TO_CONTEXT[$cpath]}"
      return 0
    fi
  fi

  bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
  if [[ -n "$bybase" ]]; then
    rel="$(rel_to_context "$bybase")"
    add_finding "INFO" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "SH001" "Resolved '$cleaned' by basename to '$rel'; verify call path."
    printf '%s\n' "$rel"
    return 0
  fi
  return 1
}

discover_shell_refs_in_text() {
  local text="$1" current_rel="$2" line="$3" phase="$4" workdir="$5"
  local -a words=()
  local word next rel i
  # shellcheck disable=SC2206
  words=($text)
  for ((i=0; i<${#words[@]}; i++)); do
    word="${words[$i]}"
    word="${word%%[;&|]*}"
    case "$(basename -- "$word")" in
      sh|bash|ksh)
        if [[ $((i + 1)) -lt ${#words[@]} ]]; then
          next="${words[$((i + 1))]}"
          if [[ "$next" == -* && $((i + 2)) -lt ${#words[@]} ]]; then
            next="${words[$((i + 2))]}"
          fi
          if [[ "$next" == *.sh* || "$next" == ./* || "$next" == /* ]]; then
            if rel="$(resolve_script_reference "$next" "$current_rel" "$line" "$phase" "$workdir")"; then
              add_shell_file "$rel" "called from $phase line $line"
            else
              local key="$current_rel:$line:$next"
              if [[ -z "${MISSING_PATH_SEEN[$key]:-}" ]]; then
                MISSING_PATH_SEEN[$key]=1
                add_finding "WARN" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "SH002" "Called shell script '$next' could not be resolved to a build-context file."
              fi
            fi
          fi
        fi
        ;;
      .|source)
        if [[ $((i + 1)) -lt ${#words[@]} ]]; then
          next="${words[$((i + 1))]}"
          if rel="$(resolve_script_reference "$next" "$current_rel" "$line" "$phase" "$workdir")"; then
            add_shell_file "$rel" "sourced from $phase line $line"
          else
            add_finding "WARN" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "SH003" "Sourced shell file '$next' could not be resolved to a build-context file."
          fi
        fi
        ;;
      *.sh|*.sh\"|*.sh\')
        if rel="$(resolve_script_reference "$word" "$current_rel" "$line" "$phase" "$workdir")"; then
          add_shell_file "$rel" "referenced from $phase line $line"
        fi
        ;;
    esac
  done
}

extract_entrypoint_script_token() {
  local body="$1"
  local -a tokens=()
  if [[ "$(trim "$body")" == "["* ]]; then
    mapfile -t tokens < <(printf '%s\n' "$body" | json_array_tokens)
  else
    # shellcheck disable=SC2206
    tokens=($body)
  fi
  (( ${#tokens[@]} == 0 )) && return 1

  local first="${tokens[0]}"
  local base
  base="$(basename -- "$first")"
  case "$base" in
    sh|bash|ksh)
      if (( ${#tokens[@]} >= 2 )); then
        if [[ "${tokens[1]}" == "-c" ]]; then
          return 1
        fi
        printf '%s\n' "${tokens[1]}"
        return 0
      fi
      ;;
    *)
      printf '%s\n' "$first"
      return 0
      ;;
  esac
  return 1
}

detect_ubi_final_image() {
  local img
  FINAL_BASE="${STAGE_BASE[$FINAL_STAGE]:-}"
  img="$(lower "$FINAL_BASE")"
  [[ "$img" == *ubi9* || "$img" == *universal-base-image-9* ]] && FINAL_IS_UBI9=1
  [[ "$img" == *9.6* ]] && FINAL_IS_UBI96=1
  [[ "$img" == *ubi-minimal* || "$img" == *minimal* ]] && FINAL_IS_UBI_MINIMAL=1

  if (( FINAL_IS_UBI9 )) && (( ! FINAL_IS_UBI96 )); then
    add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "UBI001" "Final image is UBI 9 family but is not pinned to 9.6: $FINAL_BASE"
  fi
  if [[ "$img" == *":latest"* || "$img" != *":"* ]]; then
    add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "UBI002" "Final base image tag is not explicit enough for RHEL/UBI 9.6 reproducibility: $FINAL_BASE"
  fi
}

check_ubi_run_instruction() {
  local body="$1" line="$2" stage="$3"
  (( stage == FINAL_STAGE )) || return 0
  (( FINAL_IS_UBI9 )) || return 0
  local lbody re_bash re_yum_dnf re_microdnf re_service
  lbody="$(lower "$body")"
  re_bash='(^|[[:space:];&|])bash([[:space:];&|]|$)'
  re_yum_dnf='(^|[[:space:];&|])(yum|dnf)[[:space:]]+install'
  re_microdnf='(^|[[:space:];&|])microdnf[[:space:]]+install'
  re_service='(^|[[:space:];&|])(systemctl|service)[[:space:]]'

  if [[ "$lbody" =~ $re_bash || "$lbody" == *"install bash"* ]]; then
    FINAL_INSTALLS_BASH=1
  fi
  if (( FINAL_IS_UBI_MINIMAL )) && [[ "$lbody" =~ $re_yum_dnf ]]; then
    add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI003" "UBI minimal images normally use microdnf; verify yum/dnf exists or install strategy is valid."
  fi
  if [[ "$lbody" =~ $re_microdnf ]] && [[ "$lbody" != *"clean all"* ]]; then
    add_finding "INFO" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI004" "microdnf install is not followed by clean all in the same RUN; check image size and package cache cleanup."
  fi
  if [[ "$lbody" == *"subscription-manager"* ]]; then
    add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI005" "subscription-manager appears in a UBI final stage; UBI images should not depend on host subscription state at runtime."
  fi
  if [[ "$lbody" =~ $re_service ]]; then
    add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI006" "systemctl/service usage is suspicious inside a container image."
  fi
}

analyze_dockerfile() {
  local -a stage_workdir=()
  local i inst body line stage workdir value key user
  for ((i=0; i<=FINAL_STAGE; i++)); do
    stage_workdir[$i]="/"
  done

  detect_ubi_final_image

  for ((i=0; i<${#DF_INSTR[@]}; i++)); do
    inst="${DF_INSTR[$i]}"
    body="${DF_BODY[$i]}"
    line="${DF_START[$i]}"
    stage="${DF_STAGE[$i]}"
    [[ "$stage" -lt 0 ]] && stage=0
    workdir="${stage_workdir[$stage]:-/}"

    case "$inst" in
      ARG)
        parse_arg_instruction "$body" "$line"
        ;;
      ENV)
        parse_env_instruction "$body" "$line"
        ;;
      WORKDIR)
        value="$(trim "$body")"
        stage_workdir[$stage]="$(container_abs_path "$workdir" "$value")"
        STAGE_WORKDIR_FINAL[$stage]="${stage_workdir[$stage]}"
        ;;
      COPY|ADD)
        parse_copy_add_instruction "$inst" "$body" "$line" "$stage" "$workdir"
        ;;
      RUN)
        if detect_symlink_command "$body"; then
          add_finding "INFO" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SYM001" "Symlink creation detected in Dockerfile RUN; this happens during image build, not container start."
        fi
        discover_shell_refs_in_text "$body" "" "$line" "build:stage-$stage" "$workdir"
        check_ubi_run_instruction "$body" "$line" "$stage"
        ;;
      ENTRYPOINT)
        if (( stage == FINAL_STAGE )); then
          FINAL_ENTRYPOINT_BODY="$body"
          FINAL_ENTRYPOINT_LINE="$line"
        fi
        ;;
      CMD)
        if (( stage == FINAL_STAGE )); then
          FINAL_CMD_BODY="$body"
          FINAL_CMD_LINE="$line"
        fi
        ;;
      USER)
        if (( stage == FINAL_STAGE )); then
          user="$(trim "$body")"
          FINAL_USER="$user"
          FINAL_USER_LINE="$line"
        fi
        ;;
    esac

    scan_dockerfile_var_use "$body" "$line" "build:stage-$stage"
  done

  FINAL_WORKDIR="${stage_workdir[$FINAL_STAGE]:-/}"

  for key in "${!DOCKER_ARG[@]}"; do
    if [[ -z "${DOCKER_VAR_USED[$key]:-}" ]]; then
      add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "${DOCKER_ARG_LINE[$key]}" "VAR009" "ARG '$key' is defined but not referenced later in the Dockerfile."
    fi
  done

  if (( FINAL_IS_UBI96 )); then
    if [[ -z "$FINAL_USER" ]]; then
      add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "UBI007" "Final UBI 9.6 stage does not set USER; container will run as root unless the base image defines another user."
    elif [[ "$(lower "$FINAL_USER")" == "root" || "$FINAL_USER" == "0" ]]; then
      add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "$FINAL_USER_LINE" "UBI008" "Final UBI 9.6 stage explicitly runs as root."
    fi
  fi
}

resolve_entrypoint() {
  local token rel full
  if [[ -n "$ENTRYPOINT_OVERRIDE" ]]; then
    full="$ENTRYPOINT_OVERRIDE"
    [[ "$full" != /* && ! "$full" =~ ^[A-Za-z]: ]] && full="$CONTEXT_DIR/$full"
    full="$(abs_path "$full")"
    if [[ -f "$full" || -L "$full" ]]; then
      rel="$(rel_to_context "$full")"
      add_shell_file "$rel" "entrypoint override"
    else
      add_finding "ERROR" "runtime:entrypoint" "$full" "-" "EP001" "Entrypoint override file does not exist."
    fi
    return 0
  fi

  if [[ -n "$FINAL_ENTRYPOINT_BODY" ]]; then
    if token="$(extract_entrypoint_script_token "$FINAL_ENTRYPOINT_BODY")"; then
      if rel="$(resolve_script_reference "$token" "" "$FINAL_ENTRYPOINT_LINE" "runtime:entrypoint" "$FINAL_WORKDIR")"; then
        add_shell_file "$rel" "Dockerfile ENTRYPOINT line $FINAL_ENTRYPOINT_LINE"
      else
        add_finding "WARN" "runtime:entrypoint" "$DOCKERFILE_PATH" "$FINAL_ENTRYPOINT_LINE" "EP002" "ENTRYPOINT '$token' could not be resolved to a build-context script. It may come from the base image or a generated file."
      fi
    else
      discover_shell_refs_in_text "$FINAL_ENTRYPOINT_BODY" "" "$FINAL_ENTRYPOINT_LINE" "runtime:entrypoint" "$FINAL_WORKDIR"
    fi
  elif [[ -n "$FINAL_CMD_BODY" ]]; then
    if token="$(extract_entrypoint_script_token "$FINAL_CMD_BODY")"; then
      if rel="$(resolve_script_reference "$token" "" "$FINAL_CMD_LINE" "runtime:cmd" "$FINAL_WORKDIR")"; then
        add_shell_file "$rel" "Dockerfile CMD line $FINAL_CMD_LINE"
      fi
    fi
  else
    full="$(find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f \( -iname 'entrypoint.sh' -o -iname '*entrypoint*.sh' \) -print | head -n 1)"
    if [[ -n "$full" ]]; then
      rel="$(rel_to_context "$full")"
      add_shell_file "$rel" "entrypoint filename heuristic"
      add_finding "INFO" "runtime:entrypoint" "$full" "-" "EP003" "No Dockerfile ENTRYPOINT found; scanning '$rel' by filename heuristic."
    else
      add_finding "INFO" "runtime:entrypoint" "$DOCKERFILE_PATH" "-" "EP004" "No ENTRYPOINT/CMD shell script could be resolved from the final stage."
    fi
  fi
}

literal_value_from_assignment() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%%#*}"
  value="$(trim "$value")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

substitute_known_vars() {
  local text="$1"
  shift
  local pair var value
  for pair in "$@"; do
    var="${pair%%=*}"
    value="${pair#*=}"
    text="${text//\$\{$var\}/$value}"
    text="${text//\$$var/$value}"
  done
  printf '%s' "$text"
}

extract_jboss_cli_file_arg() {
  local line="$1"
  awk '
  {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^--file=/) {
        sub(/^--file=/, "", $i); print $i; exit
      }
      if ($i == "--file" && i < NF) {
        print $(i+1); exit
      }
    }
  }' <<< "$line"
}

resolve_cli_reference() {
  local token="$1" current_rel="$2" line="$3" phase="$4"
  local cleaned="$token" full rel cpath bybase
  cleaned="${cleaned%\"}"
  cleaned="${cleaned#\"}"
  cleaned="${cleaned%\'}"
  cleaned="${cleaned#\'}"
  cleaned="${cleaned%;}"
  [[ -z "$cleaned" || "$cleaned" == *'$'* ]] && return 1

  if [[ "$cleaned" == /* ]]; then
    cpath="$(normalize_container_path "$cleaned")"
    if [[ -n "${CONTAINER_TO_CONTEXT[$cpath]:-}" ]]; then
      printf '%s\n' "${CONTAINER_TO_CONTEXT[$cpath]}"
      return 0
    fi
    bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
    if [[ -n "$bybase" ]]; then
      rel="$(rel_to_context "$bybase")"
      add_finding "INFO" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "CLI001" "Resolved CLI file '$cleaned' by basename to '$rel'; verify container path mapping."
      printf '%s\n' "$rel"
      return 0
    fi
    return 1
  fi

  full="$CONTEXT_DIR/$(dirname "$current_rel")/$cleaned"
  if [[ -f "$full" || -L "$full" ]]; then
    rel="$(rel_to_context "$full")"
    printf '%s\n' "$rel"
    return 0
  fi

  full="$CONTEXT_DIR/$cleaned"
  if [[ -f "$full" || -L "$full" ]]; then
    rel="$(rel_to_context "$full")"
    printf '%s\n' "$rel"
    return 0
  fi

  bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
  if [[ -n "$bybase" ]]; then
    rel="$(rel_to_context "$bybase")"
    add_finding "INFO" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "CLI001" "Resolved CLI file '$cleaned' by basename to '$rel'; verify call path."
    printf '%s\n' "$rel"
    return 0
  fi
  return 1
}

scan_shell_file() {
  local rel="$1" reason="$2"
  local file="$CONTEXT_DIR/$rel"
  [[ -f "$file" || -L "$file" ]] || return 0
  progress_log "CHECK" "Scanning shell script: $rel ($reason)"

  local -A assigned_line=()
  local -A used_count=()
  local -A first_use=()
  local -A literal_assign=()
  local -A exported=()
  local line no=0 code assign var value use kind lcode cli_arg cli_rel
  local -a literal_pairs=()
  local re_assign='(^|[[:space:];&|])(export|local|readonly)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)='
  local re_export='(^|[[:space:];&|])export[[:space:]]+'
  local re_read='(^|[[:space:];&|])read([[:space:]][^;&|]*)?[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)'
  local re_for='(^|[[:space:];&|])for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in[[:space:]]'
  local re_pkg='(^|[[:space:];&|])(yum|dnf|microdnf)[[:space:]]+install'
  local re_service='(^|[[:space:];&|])(systemctl|service)[[:space:]]'
  local re_useradd='(^|[[:space:];&|])(useradd|groupadd)[[:space:]]'

  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    code="${line%%#*}"
    [[ -z "$(trim "$code")" ]] && continue

    if [[ "$no" == 1 && "$line" =~ ^#!.*bash ]]; then
      if (( FINAL_IS_UBI96 && FINAL_IS_UBI_MINIMAL && ! FINAL_INSTALLS_BASH )); then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI009" "Script shebang requires bash, but final UBI 9.6 minimal stage does not clearly install bash."
      fi
    fi

    if detect_symlink_command "$code"; then
      add_finding "INFO" "runtime:$rel" "$file" "$no" "SYM002" "Symlink creation detected in shell script; this happens during container runtime/startup."
    fi

    discover_shell_refs_in_text "$code" "$rel" "$no" "runtime:$rel" "$FINAL_WORKDIR"

    if [[ "$code" =~ $re_assign ]]; then
      var="${BASH_REMATCH[3]}"
      assigned_line["$var"]="${assigned_line[$var]:-$no}"
      [[ "$code" =~ $re_export ]] && exported["$var"]=1
      value="${code#*=}"
      value="$(literal_value_from_assignment "$value")"
      literal_assign["$var"]="$value"
      if [[ -z "$value" ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR010" "Variable '$var' is initialized empty."
      fi
    fi

    if [[ "$code" =~ $re_read ]]; then
      var="${BASH_REMATCH[3]}"
      assigned_line["$var"]="${assigned_line[$var]:-$no}"
    fi

    if [[ "$code" =~ $re_for ]]; then
      var="${BASH_REMATCH[2]}"
      assigned_line["$var"]="${assigned_line[$var]:-$no}"
    fi

    literal_pairs=()
    for var in "${!literal_assign[@]}"; do
      literal_pairs+=("$var=${literal_assign[$var]}")
    done

    if [[ "$code" == *jboss-cli* ]]; then
      cli_arg="$(extract_jboss_cli_file_arg "$code")"
      cli_arg="$(substitute_known_vars "$cli_arg" "${literal_pairs[@]}")"
      if [[ -n "$cli_arg" ]]; then
        if cli_rel="$(resolve_cli_reference "$cli_arg" "$rel" "$no" "runtime:$rel")"; then
          add_cli_file "$cli_rel" "jboss-cli --file from $rel:$no"
        else
          add_finding "WARN" "runtime:$rel" "$file" "$no" "CLI002" "jboss-cli --file target '$cli_arg' could not be resolved to a build-context CLI file."
        fi
      fi
      if [[ "$code" == *"--commands="* ]]; then
        check_inline_cli_commands "$code" "$file" "$no" "runtime:$rel"
      fi
    fi

    lcode="$(lower "$code")"
    if (( FINAL_IS_UBI96 )); then
      if [[ "$lcode" =~ $re_pkg ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI010" "Package installation is being attempted from entrypoint/runtime shell on UBI 9.6; move this to Dockerfile build phase when possible."
      fi
      if [[ "$lcode" =~ $re_service ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI011" "systemctl/service usage in a UBI 9.6 container entrypoint is suspicious."
      fi
      if [[ "$lcode" == *"subscription-manager"* ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI012" "subscription-manager usage at runtime is inconsistent with portable UBI 9.6 containers."
      fi
      if (( FINAL_IS_UBI_MINIMAL )) && [[ "$lcode" =~ $re_useradd ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI013" "useradd/groupadd may be unavailable in UBI minimal runtime unless shadow-utils is installed."
      fi
    fi

    while IFS= read -r use; do
      [[ -z "$use" ]] && continue
      var="${use%%|*}"
      kind="${use#*|}"
      used_count["$var"]=$(( ${used_count[$var]:-0} + 1 ))
      first_use["$var"]="${first_use[$var]:-$no}"
      if [[ "$kind" == "required" ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR011" "Variable '$var' is required from outside or earlier initialization via \${$var:?...}."
      elif [[ "$kind" == "plain" || "$kind" == "alternate" ]]; then
        if [[ -z "${assigned_line[$var]:-}" && -z "${DOCKER_ENV[$var]:-}" ]] && ! is_standard_env_var "$var"; then
          add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR012" "Variable '$var' is used without local initialization, Dockerfile ENV, or a default; it likely must be supplied from outside."
        elif [[ -n "${assigned_line[$var]:-}" && "${assigned_line[$var]}" -gt "$no" ]]; then
          add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR013" "Variable '$var' is used before its first initialization on line ${assigned_line[$var]}."
        fi
      fi
    done < <(printf '%s\n' "$code" | extract_var_refs)
  done < "$file"

  for var in "${!assigned_line[@]}"; do
    if [[ ${used_count[$var]:-0} -eq 0 ]]; then
      if [[ -n "${exported[$var]:-}" ]]; then
        add_finding "INFO" "runtime:$rel" "$file" "${assigned_line[$var]}" "VAR014" "Exported variable '$var' is not used in this script; verify it is needed by child processes."
      else
        add_finding "WARN" "runtime:$rel" "$file" "${assigned_line[$var]}" "VAR015" "Variable '$var' is assigned but not used in this script."
      fi
    fi
  done
}

check_inline_cli_commands() {
  local code="$1" file="$2" line="$3" phase="$4"
  local commands="${code#*--commands=}"
  commands="${commands%\"}"
  commands="${commands#\"}"
  commands="${commands%\'}"
  commands="${commands#\'}"
  check_cli_line "$commands" "$file" "$line" "$phase" "inline"
}

count_char() {
  local text="$1" char="$2"
  awk -v ch="$char" '{
    for (i=1; i<=length($0); i++) {
      if (substr($0,i,1) == ch) n++
    }
  } END { print n+0 }' <<< "$text"
}

extract_cli_value() {
  local key="$1" text="$2"
  sed -n "s/.*$key[[:space:]]*=[[:space:]]*['\"]\\{0,1\\}\\([^,'\")[:space:]]*\\).*/\\1/p" <<< "$text" | head -n 1
}

check_jndi_value() {
  local value="$1" file="$2" line="$3" phase="$4" source="$5"
  [[ -z "$value" ]] && return 0
  if [[ "$value" != java:/* && "$value" != java:jboss/* ]]; then
    add_finding "WARN" "$phase" "$file" "$line" "JNDI001" "$source JNDI value '$value' does not start with java:/ or java:jboss/."
  fi
  if [[ "$value" == *'$'* ]]; then
    add_finding "WARN" "$phase" "$file" "$line" "JNDI002" "$source JNDI value '$value' contains a variable; ensure it has a safe default or required external value."
  fi
  local key="$file:$value"
  if [[ -n "${CLI_JNDI_SEEN[$key]:-}" ]]; then
    add_finding "WARN" "$phase" "$file" "$line" "JNDI003" "Duplicate JNDI value '$value' also appears on line ${CLI_JNDI_SEEN[$key]}."
  else
    CLI_JNDI_SEEN[$key]="$line"
  fi
}

check_cli_line() {
  local line_text="$1" file="$2" line="$3" phase="$4" cli_name="$5"
  local code jndi binding_type dquotes lpar rpar lbrace rbrace lbrack rbrack
  local re_type_param='(^|[,(]|[[:space:]])type[[:space:]]*='
  local re_value_param='(^|[,(]|[[:space:]])value[[:space:]]*='
  local re_lookup_param='(^|[,(]|[[:space:]])lookup[[:space:]]*='
  code="$(trim "${line_text%%#*}")"
  [[ -z "$code" ]] && return 0

  dquotes=$(awk '{
    n=0; esc=0;
    for (i=1; i<=length($0); i++) {
      c=substr($0,i,1);
      if (esc) { esc=0; continue; }
      if (c=="\\") { esc=1; continue; }
      if (c=="\"") n++;
    }
    print n;
  }' <<< "$code")
  if (( dquotes % 2 == 1 )); then
    add_finding "ERROR" "$phase" "$file" "$line" "CLI003" "$cli_name has an unmatched double quote."
  fi

  lpar=$(count_char "$code" "("); rpar=$(count_char "$code" ")")
  lbrace=$(count_char "$code" "{"); rbrace=$(count_char "$code" "}")
  lbrack=$(count_char "$code" "["); rbrack=$(count_char "$code" "]")
  if (( lpar != rpar || lbrace != rbrace || lbrack != rbrack )); then
    add_finding "ERROR" "$phase" "$file" "$line" "CLI004" "$cli_name has unbalanced (), {}, or [] delimiters."
  fi

  case "$code" in
    /*|:*|if\ *|else|end-if|try|catch|finally|end-try|batch|run-batch|discard-batch|embed-server*|stop-embedded-server*|connect*|cd\ *|ls*|echo\ *|quit|reload*)
      ;;
    *)
      add_finding "INFO" "$phase" "$file" "$line" "CLI005" "$cli_name line does not look like a standard jboss-cli command; verify syntax."
      ;;
  esac

  if [[ "$code" == *"jndi-name"* ]]; then
    jndi="$(extract_cli_value "jndi-name" "$code")"
    check_jndi_value "$jndi" "$file" "$line" "$phase" "jboss-cli"
  fi

  if [[ "$code" == *"/subsystem=naming/binding="* || "$code" == *"binding="*":add("* ]]; then
    binding_type="$(extract_cli_value "binding-type" "$code")"
    if [[ -z "$binding_type" ]]; then
      add_finding "WARN" "$phase" "$file" "$line" "JNDI004" "Naming binding add operation has no binding-type."
    elif [[ "$binding_type" == "simple" ]]; then
      [[ "$code" =~ $re_type_param ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI005" "JNDI simple binding is missing type=."
      [[ "$code" =~ $re_value_param ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI006" "JNDI simple binding is missing value=."
    elif [[ "$binding_type" == "lookup" ]]; then
      [[ "$code" =~ $re_lookup_param ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI007" "JNDI lookup binding is missing lookup=."
    fi
  fi

  if [[ "$code" == *"data-source"*":add("* || "$code" == data-source\ add* || "$code" == *"xa-data-source"*":add("* ]]; then
    [[ "$code" == *"jndi-name"* ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI008" "Datasource add operation has no jndi-name=."
  fi
}

scan_cli_file() {
  local rel="$1" reason="$2"
  local file="$CONTEXT_DIR/$rel"
  [[ -f "$file" || -L "$file" ]] || return 0
  progress_log "CHECK" "Scanning WildFly CLI file: $rel ($reason)"

  local line no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    check_cli_line "$line" "$file" "$no" "runtime:jboss-cli" "$rel"
  done < "$file"
}

discover_cli_files_by_extension() {
  local full rel
  while IFS= read -r -d '' full; do
    rel="$(rel_to_context "$full")"
    if [[ -n "${REFERENCED_CONTEXT[$rel]:-}" ]]; then
      add_cli_file "$rel" "referenced build-context CLI file"
    fi
  done < <(find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f -iname '*.cli' -print0)
}

scan_all_shells() {
  local progress=1 rel
  progress_log "CHECK" "Resolving and scanning entrypoint/called shell scripts"
  while (( progress )); do
    progress=0
    for rel in "${!SHELL_FILES[@]}"; do
      if [[ "${SHELL_FILES[$rel]}" == "1" ]]; then
        SHELL_FILES["$rel"]="scanned"
        scan_shell_file "$rel" "${SHELL_REASON[$rel]}"
        progress=1
      fi
    done
  done
}

scan_all_cli() {
  local rel
  progress_log "CHECK" "Resolving and scanning WildFly jboss-cli files"
  discover_cli_files_by_extension
  for rel in "${!CLI_FILES[@]}"; do
    scan_cli_file "$rel" "${CLI_REASON[$rel]}"
  done
}

report_unused_context_files() {
  local full rel
  progress_log "CHECK" "Scanning unreferenced build-context files"
  while IFS= read -r -d '' full; do
    rel="$(rel_to_context "$full")"
    [[ "$rel" == .git/* ]] && continue
    if [[ -z "${REFERENCED_CONTEXT[$rel]:-}" ]] && is_relevant_context_file "$rel"; then
      add_finding "INFO" "build-context" "$full" "-" "CTX010" "Build context file '$rel' is not referenced by COPY/ADD in the Dockerfile."
    fi
  done < <(find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f -print0 -o -type l -print0)
}

check_item_for_code() {
  case "$1" in
    DF*) printf 'Dockerfile syntax and multi-stage build' ;;
    CTX*) printf 'Build context resource relation' ;;
    SYM*) printf 'Symbolic link creation phase' ;;
    EP*) printf 'Entrypoint resolution' ;;
    SH*) printf 'Called shell script relation' ;;
    VAR*) printf 'Shell and Dockerfile variable usage' ;;
    UBI*) printf 'UBI 9.6 runtime consistency' ;;
    CLI*) printf 'WildFly jboss-cli syntax' ;;
    JNDI*) printf 'WildFly JNDI configuration' ;;
    SUMMARY) printf 'Check category summary' ;;
    *) printf 'Static check' ;;
  esac
}

result_label_for_severity() {
  case "$1" in
    ERROR) printf '要修正' ;;
    WARN) printf '要確認/改善推奨' ;;
    INFO) printf '情報' ;;
    OK) printf 'OK' ;;
    *) printf '%s' "$1" ;;
  esac
}

suggestion_for_code() {
  local code="$1"
  case "$code" in
    DF001|DF003) printf 'FROM命令を追加し、利用するベースイメージを明示してください。' ;;
    DF002) printf 'マルチステージ名を一意にしてください。COPY --fromで参照しやすい名前に整理するのが安全です。' ;;
    DF004|DF006) printf 'COPY --fromの参照先を既存のステージ番号またはASで定義したステージ名に修正してください。' ;;
    DF005) printf '外部イメージからのCOPYであることを意図しているか確認し、タグを固定してください。' ;;
    DF007) printf 'BuildKitの--link利用が対象環境で有効か確認してください。' ;;
    DF008) printf 'COPY/ADDは少なくとも1つのソースと1つの宛先を指定してください。' ;;
    CTX001) printf '変数を含むCOPY/ADD元は静的解析が難しいため、ARG/ENVの既定値や実ビルド時の値を明記してください。' ;;
    CTX002) printf 'Dockerビルドコンテキスト外のファイルは直接参照できません。必要な資材をコンテキスト内へ配置してください。' ;;
    CTX003) printf '.dockerignoreから除外されているため、COPY/ADD対象にする場合は除外ルールを見直してください。' ;;
    CTX004) printf '破損したシンボリックリンクの参照先を修正するか、実体ファイルを配置してください。' ;;
    CTX005) printf 'コンテキスト外を指すシンボリックリンクはビルド環境差分の原因になります。実体をコンテキスト内に置くことを推奨します。' ;;
    CTX006) printf 'ホスト側コンテキストで提供されるリンクです。Docker build時に期待どおり解決されるか確認してください。' ;;
    CTX007|CTX008) printf 'COPY/ADD元パス、ファイル名、大文字小文字、配置ディレクトリを修正してください。' ;;
    CTX009) printf 'ADDによるリモート取得は再現性が落ちます。可能なら事前取得してコンテキストに含めてください。' ;;
    CTX010) printf '未使用資材であれば削除し、必要な資材ならDockerfileのCOPY/ADDまたは参照経路を追加してください。' ;;
    SYM001) printf 'ビルド時に固定で必要なリンクならDockerfileで妥当です。起動時の状態に依存するならentrypoint側へ移してください。' ;;
    SYM002) printf 'runtimeで作るリンクは冪等性、既存リンク、権限、実行ユーザーを確認してください。固定リンクならDockerfile側で作る方が安定します。' ;;
    EP001|EP002) printf 'ENTRYPOINT/CMDのパスとCOPY先を一致させ、実行権限とshebangも確認してください。' ;;
    EP003|EP004) printf 'DockerfileのENTRYPOINT/CMDを明示するか、--entrypointで解析対象を指定してください。' ;;
    SH001) printf 'basenameによる推定解決です。実際のコンテナ内パスとCOPY先が一致しているか確認してください。' ;;
    SH002|SH003) printf '呼び出し先シェルをビルドコンテキスト内に配置し、COPY先と実行パスを合わせてください。' ;;
    VAR001|VAR003|VAR005) printf '変数定義の構文を修正し、名前と値を明示してください。' ;;
    VAR002) printf 'ENVはkey=value形式へ揃えるとDockerfileの可読性と解析精度が上がります。' ;;
    VAR004|VAR010) printf '空値が意図した初期値か確認し、必要なら既定値を設定してください。' ;;
    VAR006) printf 'ARGに既定値を設定するか、ビルド時に必須で渡すことをREADMEやCIに明記してください。' ;;
    VAR007|VAR011) printf '外部から必須で受け取る変数です。環境変数、secret、起動引数、CI設定のいずれで渡すか明記してください。' ;;
    VAR008|VAR012|VAR013) printf '利用前に初期化するか、${VAR:-default}のような既定値、または${VAR:?message}の必須チェックを追加してください。' ;;
    VAR009|VAR014|VAR015) printf '不要なら削除し、子プロセス向けに必要なら用途をコメントや命名で明確にしてください。' ;;
    UBI001|UBI002) printf 'RHEL/UBI 9.6前提ならベースイメージタグを9.6に固定してください。' ;;
    UBI003|UBI004) printf 'UBI minimalではmicrodnf利用とキャッシュ削除を確認してください。パッケージ導入はDockerfileビルド時に寄せるのが基本です。' ;;
    UBI005|UBI012) printf 'subscription-managerに依存しない構成へ見直してください。UBIコンテナはホスト購読状態へ依存させない方が移植性があります。' ;;
    UBI006|UBI011) printf 'systemctl/serviceは通常コンテナ内で期待どおり動きません。プロセスを直接起動するentrypointへ変更してください。' ;;
    UBI007|UBI008) printf '可能なら非rootユーザーを作成し、USERで実行ユーザーを固定してください。必要な権限はビルド時にchown/chmodします。' ;;
    UBI009) printf 'UBI minimalでbash shebangを使う場合はDockerfileでbashを導入するか、/bin/sh互換に修正してください。' ;;
    UBI010) printf 'entrypoint実行時のパッケージ導入は再現性と起動時間を悪化させます。DockerfileのRUNへ移動してください。' ;;
    UBI013) printf 'UBI minimalでuseradd/groupaddを使う場合はshadow-utils導入を確認するか、ビルド時にユーザー作成してください。' ;;
    CLI001) printf '推定解決されたCLIファイルです。jboss-cli.sh --fileのパスとCOPY先の対応を確認してください。' ;;
    CLI002) printf 'CLIファイルをビルドコンテキストに配置し、DockerfileでCOPYしたコンテナ内パスを--fileに指定してください。' ;;
    CLI003|CLI004) printf 'jboss-cliの括弧、引用符、複合値の閉じ忘れを修正してください。' ;;
    CLI005) printf 'WildFly jboss-cliで有効なコマンドか確認し、必要ならbatch/run-batchや/subsystem=...形式へ整理してください。' ;;
    JNDI001) printf 'WildFly/JBossのJNDI名は通常java:/またはjava:jboss/から始めます。アプリ側参照名と合わせて修正してください。' ;;
    JNDI002) printf 'JNDI値に変数を使う場合は既定値や必須チェックを追加し、空値で起動しないようにしてください。' ;;
    JNDI003) printf '重複JNDI名は衝突の原因になります。意図した上書きか、別名にすべきか確認してください。' ;;
    JNDI004|JNDI005|JNDI006|JNDI007|JNDI008) printf 'JNDI/naming/datasource追加に必要な属性を補完し、WildFlyの対象バージョンのCLI仕様に合わせてください。' ;;
    SUMMARY) printf '該当カテゴリの詳細行を確認してください。OKの場合はこのカテゴリで検出された問題はありません。' ;;
    *) printf '対象行の実装意図と実行環境を確認し、必要に応じてDockerfileまたは関連スクリプトを修正してください。' ;;
  esac
}

csv_escape() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

write_csv_row() {
  local field first=1
  for field in "$@"; do
    if (( first )); then
      first=0
    else
      printf ',' >> "$REPORT_FILE"
    fi
    csv_escape "$field" >> "$REPORT_FILE"
  done
  printf '\n' >> "$REPORT_FILE"
}

count_codes_by_sev() {
  local sev="$1"
  shift
  local prefix count=0 i code wanted
  for ((i=0; i<${#F_SEV[@]}; i++)); do
    [[ "${F_SEV[$i]}" == "$sev" ]] || continue
    code="${F_CODE[$i]}"
    for wanted in "$@"; do
      if [[ "$code" == "$wanted"* ]]; then
        count=$((count + 1))
        break
      fi
    done
  done
  printf '%s' "$count"
}

write_summary_csv_row() {
  local -n serial_ref="$1"
  local category="$2"
  shift 2
  local errors warns infos severity result msg
  errors=$(count_codes_by_sev "ERROR" "$@")
  warns=$(count_codes_by_sev "WARN" "$@")
  infos=$(count_codes_by_sev "INFO" "$@")
  if (( errors > 0 )); then
    severity="ERROR"
    result="要修正"
  elif (( warns > 0 )); then
    severity="WARN"
    result="要確認/改善推奨"
  elif (( infos > 0 )); then
    severity="INFO"
    result="情報"
  else
    severity="OK"
    result="OK"
  fi
  msg="$category: ERROR=$errors WARN=$warns INFO=$infos"
  write_csv_row "$serial_ref" "$result" "$severity" "SUMMARY" "$category" "summary" "-" "-" "$msg" "$(suggestion_for_code SUMMARY)"
  serial_ref=$((serial_ref + 1))
}

write_report_file() {
  (( REPORT_ENABLED )) || return 0
  local dir serial=1 i file line sev code result item msg suggestion
  dir="$(dirname -- "$REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel CSV report: $REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$REPORT_FILE"
  write_csv_row "No" "Result" "Severity" "CheckCode" "CheckItem" "Phase" "File" "Line" "Message" "Suggestion"

  write_summary_csv_row serial "Dockerfile構文/マルチステージ" "DF"
  write_summary_csv_row serial "ビルドコンテキスト資材関連" "CTX"
  write_summary_csv_row serial "シンボリックリンク作成フェーズ" "SYM"
  write_summary_csv_row serial "ENTRYPOINT/CMD解決" "EP"
  write_summary_csv_row serial "呼び出しシェル関連" "SH"
  write_summary_csv_row serial "変数利用/初期化" "VAR"
  write_summary_csv_row serial "WildFly jboss-cli構文" "CLI"
  write_summary_csv_row serial "WildFly JNDI設定" "JNDI"
  write_summary_csv_row serial "UBI 9.6 runtime整合性" "UBI"

  for ((i=0; i<${#F_SEV[@]}; i++)); do
    sev="${F_SEV[$i]}"
    code="${F_CODE[$i]}"
    result="$(result_label_for_severity "$sev")"
    item="$(check_item_for_code "$code")"
    file="$(display_path "${F_FILE[$i]}")"
    line="${F_LINE[$i]}"
    msg="${F_MSG[$i]}"
    suggestion="$(suggestion_for_code "$code")"
    write_csv_row "$serial" "$result" "$sev" "$code" "$item" "${F_PHASE[$i]}" "$file" "$line" "$msg" "$suggestion"
    serial=$((serial + 1))
  done
}

print_header() {
  local stages stage_label
  stages=$((FINAL_STAGE + 1))
  stage_label="$FINAL_STAGE"
  [[ -n "${STAGE_NAME[$FINAL_STAGE]:-}" ]] && stage_label+=" (${STAGE_NAME[$FINAL_STAGE]})"

  printf 'Docker Context Checker %s\n' "$VERSION"
  printf 'Context    : %s\n' "$CONTEXT_DIR"
  printf 'Dockerfile : %s\n' "$DOCKERFILE_PATH"
  printf 'Stages     : %s\n' "$stages"
  if (( FINAL_STAGE >= 0 )); then
    printf 'Final stage: %s, base=%s, workdir=%s\n' "$stage_label" "$FINAL_BASE" "$FINAL_WORKDIR"
    if (( FINAL_IS_UBI96 )); then
      printf 'UBI check  : final image is detected as Universal Base Image 9.6%s\n' "$([[ $FINAL_IS_UBI_MINIMAL -eq 1 ]] && printf ' minimal' || true)"
    elif (( FINAL_IS_UBI9 )); then
      printf 'UBI check  : final image is UBI 9 family but not detected as 9.6\n'
    else
      printf 'UBI check  : final image is not detected as UBI 9.6\n'
    fi
  fi
  printf 'Summary    : ERROR=%s WARN=%s INFO=%s\n' "${F_COUNT[ERROR]:-0}" "${F_COUNT[WARN]:-0}" "${F_COUNT[INFO]:-0}"
  if (( REPORT_ENABLED )); then
    printf 'CSV report : %s\n' "$REPORT_FILE"
  fi
  printf '\n'
}

print_findings_for() {
  local sev="$1" i file line phase
  local count=0
  for ((i=0; i<${#F_SEV[@]}; i++)); do
    [[ "${F_SEV[$i]}" == "$sev" ]] || continue
    count=$((count + 1))
    file="$(display_path "${F_FILE[$i]}")"
    line="${F_LINE[$i]}"
    phase="${F_PHASE[$i]}"
    printf '[%s] %-18s %s:%s %s  %s\n' "$sev" "$phase" "$file" "$line" "${F_CODE[$i]}" "${F_MSG[$i]}"
  done
  (( count > 0 ))
}

print_report() {
  print_header
  if (( ${#F_SEV[@]} == 0 )); then
    printf 'No findings.\n'
    return 0
  fi
  print_findings_for "ERROR" || true
  print_findings_for "WARN" || true
  print_findings_for "INFO" || true
}

main() {
  parse_args "$@"
  CONTEXT_DIR="$(abs_path "$CONTEXT_DIR")"
  [[ -d "$CONTEXT_DIR" ]] || die "Context directory does not exist: $CONTEXT_DIR"
  if [[ -z "$DOCKERFILE_PATH" ]]; then
    DOCKERFILE_PATH="$CONTEXT_DIR/Dockerfile"
  elif [[ "$DOCKERFILE_PATH" != /* && ! "$DOCKERFILE_PATH" =~ ^[A-Za-z]: ]]; then
    DOCKERFILE_PATH="$CONTEXT_DIR/$DOCKERFILE_PATH"
  fi
  DOCKERFILE_PATH="$(abs_path "$DOCKERFILE_PATH")"
  [[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile does not exist: $DOCKERFILE_PATH"
  if (( REPORT_ENABLED )); then
    [[ -z "$REPORT_FILE" ]] && REPORT_FILE="$PWD/docker-context-checker-results.csv"
    REPORT_FILE="$(abs_path "$REPORT_FILE")"
  fi

  progress_log "START" "Context=$CONTEXT_DIR Dockerfile=$DOCKERFILE_PATH"
  progress_log "CHECK" "Loading .dockerignore patterns"
  load_dockerignore
  progress_log "CHECK" "Parsing Dockerfile instructions and multi-stage definitions"
  parse_dockerfile
  if (( FINAL_STAGE >= 0 )); then
    progress_log "CHECK" "Analyzing Dockerfile COPY/ADD/RUN/ARG/ENV/UBI checks"
    analyze_dockerfile
    progress_log "CHECK" "Resolving ENTRYPOINT/CMD shell targets"
    resolve_entrypoint
    scan_all_shells
    scan_all_cli
    report_unused_context_files
  fi
  progress_log "DONE" "Static checks completed"
  write_report_file
  print_report

  case "$FAIL_ON" in
    error)
      (( ${F_COUNT[ERROR]:-0} == 0 )) || exit 1
      ;;
    warn)
      (( ${F_COUNT[ERROR]:-0} == 0 && ${F_COUNT[WARN]:-0} == 0 )) || exit 1
      ;;
    never)
      ;;
  esac
}

main "$@"
