#!/usr/bin/env bash
# Council — Repository Understanding Engine
# Analyzes a repo and produces .council/project_model.json

# Language detection by file extension
declare -A LANG_EXTENSIONS=(
    [go]="go"
    [js]="javascript" [jsx]="javascript" [mjs]="javascript" [cjs]="javascript"
    [ts]="typescript" [tsx]="typescript" [mts]="typescript"
    [py]="python" [pyx]="python"
    [rs]="rust"
    [rb]="ruby"
    [java]="java"
    [kt]="kotlin" [kts]="kotlin"
    [swift]="swift"
    [c]="c" [h]="c"
    [cpp]="cpp" [cc]="cpp" [cxx]="cpp" [hpp]="cpp"
    [cs]="csharp"
    [php]="php"
    [sh]="shell" [bash]="shell" [zsh]="shell"
    [lua]="lua"
    [zig]="zig"
    [ex]="elixir" [exs]="elixir"
    [erl]="erlang"
    [hs]="haskell"
    [ml]="ocaml" [mli]="ocaml"
    [scala]="scala"
    [clj]="clojure" [cljs]="clojure"
    [dart]="dart"
    [vue]="vue"
    [svelte]="svelte"
)

# Framework detection rules: dependency name -> framework
declare -A FRAMEWORK_RULES=(
    [react]="React"
    [next]="Next.js"
    [vue]="Vue"
    [nuxt]="Nuxt"
    [svelte]="Svelte"
    [angular]="Angular"
    [express]="Express"
    [fastify]="Fastify"
    [django]="Django"
    [flask]="Flask"
    [fastapi]="FastAPI"
    [rails]="Rails"
    [gin-gonic/gin]="Gin"
    [echo]="Echo"
    [fiber]="Fiber"
    [actix-web]="Actix"
    [axum]="Axum"
    [tokio]="Tokio"
    [spring]="Spring"
    [laravel]="Laravel"
    [phoenix]="Phoenix"
)

# Get list of source files, respecting .gitignore
_repo_files() {
    local dir="$1"
    if [[ -d "$dir/.git" ]] && has_cmd git; then
        git -C "$dir" ls-files --cached --others --exclude-standard 2>/dev/null
    else
        # Fallback: find with common exclusions
        find "$dir" -type f \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/vendor/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/target/*' \
            -not -path '*/.council/*' \
            -not -path '*/.venv/*' \
            -not -path '*/dist/*' \
            -not -path '*/build/*' \
            -not -name '*.min.js' \
            -not -name '*.min.css' \
            -not -name '*.map' \
            2>/dev/null | sed "s|^$dir/||"
    fi
}

# Phase 1: Scan filesystem — detect languages, entry points, structure
_repo_scan() {
    local dir="$1"
    local state_dir
    state_dir="$(council_state_dir "$dir")"

    declare -A lang_files=()
    declare -A lang_lines=()
    local total_files=0
    local total_lines=0
    local entry_points=""
    local test_dirs=""
    local config_files=""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local ext="${file##*.}"
        local lang="${LANG_EXTENSIONS[$ext]:-}"
        local full="$dir/$file"

        [[ ! -f "$full" ]] && continue

        total_files=$((total_files + 1))

        # Count lines (fast)
        local lc
        lc=$(wc -l < "$full" 2>/dev/null || echo 0)
        total_lines=$((total_lines + lc))

        if [[ -n "$lang" ]]; then
            lang_files[$lang]=$(( ${lang_files[$lang]:-0} + 1 ))
            lang_lines[$lang]=$(( ${lang_lines[$lang]:-0} + lc ))
        fi

        # Detect entry points
        case "$file" in
            main.go|cmd/*/main.go) entry_points+="\"$file\"," ;;
            index.ts|index.js|src/index.*|src/main.*) entry_points+="\"$file\"," ;;
            app.py|main.py|manage.py|wsgi.py) entry_points+="\"$file\"," ;;
            src/main.rs|src/lib.rs) entry_points+="\"$file\"," ;;
            Makefile|makefile) config_files+="\"$file\"," ;;
            Dockerfile|docker-compose.yml|docker-compose.yaml) config_files+="\"$file\"," ;;
            .github/workflows/*.yml|.github/workflows/*.yaml) config_files+="\"$file\"," ;;
            tsconfig.json|webpack.config.*|vite.config.*) config_files+="\"$file\"," ;;
        esac

        # Detect test directories
        case "$file" in
            *_test.go|*_test.py|*.test.ts|*.test.js|*.spec.ts|*.spec.js)
                local tdir
                tdir="$(dirname "$file")"
                if [[ ! "$test_dirs" == *"\"$tdir\""* ]]; then
                    test_dirs+="\"$tdir\","
                fi
                ;;
        esac
        case "$file" in
            __tests__/*|test/*|tests/*|spec/*)
                local tdir="${file%%/*}"
                if [[ ! "$test_dirs" == *"\"$tdir\""* ]]; then
                    test_dirs+="\"$tdir\","
                fi
                ;;
        esac

    done < <(_repo_files "$dir")

    # Build languages JSON array
    local langs_json="["
    local lang_count="${#lang_files[@]}"
    if [[ $lang_count -gt 0 ]]; then
        for lang in "${!lang_files[@]}"; do
            local pct=0
            if [[ $total_lines -gt 0 ]]; then
                pct=$(( (${lang_lines[$lang]} * 100) / total_lines ))
            fi
            langs_json+="{\"name\":\"$lang\",\"file_count\":${lang_files[$lang]},\"line_count\":${lang_lines[$lang]},\"percentage\":$pct},"
        done
    fi
    langs_json="${langs_json%,}]"

    # Write scan results as JSON
    cat > "$state_dir/cache/scan.json" <<EOJSON
{
  "total_files": $total_files,
  "total_lines": $total_lines,
  "languages": $langs_json,
  "entry_points": [${entry_points%,}],
  "test_dirs": [${test_dirs%,}],
  "config_files": [${config_files%,}]
}
EOJSON

    local lang_count="${#lang_files[@]}"
    ui_info "Scanned $total_files files ($total_lines lines) — $lang_count language(s)"
}

# Phase 2: Parse dependencies and detect frameworks
_repo_deps() {
    local dir="$1"
    local state_dir
    state_dir="$(council_state_dir "$dir")"

    local deps_json="["
    local frameworks_json="["
    local detected_frameworks=""

    # go.mod
    if [[ -f "$dir/go.mod" ]]; then
        while IFS= read -r line; do
            local mod ver
            mod="$(echo "$line" | awk '{print $1}')"
            ver="$(echo "$line" | awk '{print $2}')"
            [[ -z "$mod" || "$mod" == "module" || "$mod" == "go" || "$mod" == "require" || "$mod" == ")" ]] && continue
            deps_json+="{\"name\":\"$mod\",\"version\":\"$ver\",\"source\":\"go.mod\"},"
            # Framework check
            for rule in "${!FRAMEWORK_RULES[@]}"; do
                if [[ "$mod" == *"$rule"* && ! "$detected_frameworks" == *"${FRAMEWORK_RULES[$rule]}"* ]]; then
                    frameworks_json+="\"${FRAMEWORK_RULES[$rule]}\","
                    detected_frameworks+="${FRAMEWORK_RULES[$rule]} "
                fi
            done
        done < <(sed -n '/^require/,/^)/p' "$dir/go.mod" 2>/dev/null | grep -v '^require\|^)')
    fi

    # package.json
    if [[ -f "$dir/package.json" ]] && has_cmd jq; then
        local pkg="$dir/package.json"
        for section in ".dependencies" ".devDependencies"; do
            while IFS='=' read -r name ver; do
                [[ -z "$name" ]] && continue
                deps_json+="{\"name\":\"$name\",\"version\":\"$ver\",\"source\":\"package.json\"},"
                for rule in "${!FRAMEWORK_RULES[@]}"; do
                    if [[ "$name" == "$rule" || "$name" == "@${rule}/"* ]] && [[ ! "$detected_frameworks" == *"${FRAMEWORK_RULES[$rule]}"* ]]; then
                        frameworks_json+="\"${FRAMEWORK_RULES[$rule]}\","
                        detected_frameworks+="${FRAMEWORK_RULES[$rule]} "
                    fi
                done
            done < <(jq -r "$section // {} | to_entries[] | \"\(.key)=\(.value)\"" "$pkg" 2>/dev/null)
        done
        # next.config detection
        if ls "$dir"/next.config.* &>/dev/null && [[ ! "$detected_frameworks" == *"Next.js"* ]]; then
            frameworks_json+="\"Next.js\","
        fi
    fi

    # requirements.txt
    if [[ -f "$dir/requirements.txt" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == "#"* ]] && continue
            local name ver
            name="$(echo "$line" | sed 's/[>=<].*//' | tr -d ' ')"
            ver="$(echo "$line" | grep -oP '[>=<]+.*' || echo "")"
            deps_json+="{\"name\":\"$name\",\"version\":\"$ver\",\"source\":\"requirements.txt\"},"
            for rule in "${!FRAMEWORK_RULES[@]}"; do
                if [[ "$name" == "$rule" ]] && [[ ! "$detected_frameworks" == *"${FRAMEWORK_RULES[$rule]}"* ]]; then
                    frameworks_json+="\"${FRAMEWORK_RULES[$rule]}\","
                    detected_frameworks+="${FRAMEWORK_RULES[$rule]} "
                fi
            done
        done < "$dir/requirements.txt"
    fi

    # pyproject.toml — basic extraction
    if [[ -f "$dir/pyproject.toml" ]]; then
        while IFS= read -r line; do
            local name
            name="$(echo "$line" | sed 's/[>=<].*//' | tr -d ' ",' | tr -d "'")"
            [[ -z "$name" || "$name" == "[" || "$name" == "]" ]] && continue
            deps_json+="{\"name\":\"$name\",\"version\":\"\",\"source\":\"pyproject.toml\"},"
        done < <(sed -n '/^dependencies/,/^\[/p' "$dir/pyproject.toml" 2>/dev/null | grep -v '^\[' | grep -v '^dependencies')
    fi

    # Cargo.toml — basic extraction
    if [[ -f "$dir/Cargo.toml" ]]; then
        while IFS= read -r line; do
            local name ver
            name="$(echo "$line" | cut -d'=' -f1 | tr -d ' ')"
            ver="$(echo "$line" | cut -d'=' -f2- | tr -d ' "' )"
            [[ -z "$name" || "$name" == "["* ]] && continue
            deps_json+="{\"name\":\"$name\",\"version\":\"$ver\",\"source\":\"Cargo.toml\"},"
            for rule in "${!FRAMEWORK_RULES[@]}"; do
                if [[ "$name" == *"$rule"* ]] && [[ ! "$detected_frameworks" == *"${FRAMEWORK_RULES[$rule]}"* ]]; then
                    frameworks_json+="\"${FRAMEWORK_RULES[$rule]}\","
                    detected_frameworks+="${FRAMEWORK_RULES[$rule]} "
                fi
            done
        done < <(sed -n '/^\[dependencies\]/,/^\[/p' "$dir/Cargo.toml" 2>/dev/null | grep '=' | grep -v '^\[')
    fi

    # Gemfile — basic extraction
    if [[ -f "$dir/Gemfile" ]]; then
        while IFS= read -r line; do
            local name
            name="$(echo "$line" | grep "^gem " | sed "s/gem ['\"]//;s/['\"].*//")"
            [[ -z "$name" ]] && continue
            deps_json+="{\"name\":\"$name\",\"version\":\"\",\"source\":\"Gemfile\"},"
            if [[ "$name" == "rails" ]] && [[ ! "$detected_frameworks" == *"Rails"* ]]; then
                frameworks_json+="\"Rails\","
            fi
        done < "$dir/Gemfile"
    fi

    deps_json="${deps_json%,}]"
    frameworks_json="${frameworks_json%,}]"

    cat > "$state_dir/cache/deps.json" <<EOJSON
{
  "dependencies": $deps_json,
  "frameworks": $frameworks_json
}
EOJSON

    local dep_count
    dep_count="$(echo "$deps_json" | jq 'length' 2>/dev/null || echo "?")"
    ui_info "Found $dep_count dependencies, frameworks: ${detected_frameworks:-none}"
}

# Phase 3: Build project model
_repo_build_model() {
    local dir="$1"
    local state_dir
    state_dir="$(council_state_dir "$dir")"
    local scan="$state_dir/cache/scan.json"
    local deps="$state_dir/cache/deps.json"

    # Detect build/test commands
    local build_cmd="" test_cmd=""
    if [[ -f "$dir/Makefile" ]]; then
        grep -q "^test:" "$dir/Makefile" 2>/dev/null && test_cmd="make test"
        grep -q "^build:" "$dir/Makefile" 2>/dev/null && build_cmd="make build"
    fi
    [[ -f "$dir/package.json" ]] && has_cmd jq && {
        local scripts
        scripts="$(jq -r '.scripts // {}' "$dir/package.json")"
        echo "$scripts" | jq -e '.test' &>/dev/null && test_cmd="${test_cmd:-npm test}"
        echo "$scripts" | jq -e '.build' &>/dev/null && build_cmd="${build_cmd:-npm run build}"
    }
    [[ -f "$dir/go.mod" ]] && {
        test_cmd="${test_cmd:-go test ./...}"
        build_cmd="${build_cmd:-go build ./...}"
    }
    [[ -f "$dir/Cargo.toml" ]] && {
        test_cmd="${test_cmd:-cargo test}"
        build_cmd="${build_cmd:-cargo build}"
    }
    [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]] && {
        test_cmd="${test_cmd:-pytest}"
    }

    # Merge into project model
    require_jq
    jq -n \
        --arg root "$dir" \
        --arg scanned_at "$(now_ts)" \
        --arg build_cmd "$build_cmd" \
        --arg test_cmd "$test_cmd" \
        --slurpfile scan "$scan" \
        --slurpfile deps "$deps" \
    '{
        root_path: $root,
        languages: $scan[0].languages,
        total_files: $scan[0].total_files,
        total_lines: $scan[0].total_lines,
        entry_points: $scan[0].entry_points,
        test_dirs: $scan[0].test_dirs,
        config_files: $scan[0].config_files,
        dependencies: $deps[0].dependencies,
        frameworks: $deps[0].frameworks,
        build_command: $build_cmd,
        test_command: $test_cmd,
        scanned_at: $scanned_at
    }' > "$state_dir/project_model.json"

    ui_success "Project model written to .council/project_model.json"
}

# Check if the repo is greenfield (empty or near-empty)
repo_is_greenfield() {
    local dir="$1"
    local model="$dir/$COUNCIL_DIR/project_model.json"
    [[ ! -f "$model" ]] && return 0

    local total_files
    total_files="$(jq -r '.total_files // 0' "$model" 2>/dev/null)"
    # Consider greenfield if fewer than 3 source files (ignoring .git, configs, etc.)
    local source_count=0
    if has_cmd jq; then
        source_count="$(jq -r '[.languages[].file_count] | add // 0' "$model" 2>/dev/null)"
    fi
    [[ "$source_count" -lt 3 ]]
}

# Store greenfield project preferences into the model
repo_set_greenfield_prefs() {
    local dir="$1"
    local language="$2"
    local framework="$3"
    local description="$4"

    local model="$dir/$COUNCIL_DIR/project_model.json"
    [[ ! -f "$model" ]] && return

    require_jq
    local tmp
    tmp="$(mktemp)"
    jq \
        --arg lang "$language" \
        --arg fw "$framework" \
        --arg desc "$description" \
    '. + {
        greenfield: true,
        intended_language: $lang,
        intended_framework: $fw,
        project_description: $desc
    }' "$model" > "$tmp" && mv "$tmp" "$model"
}

# Main analysis entry point
repo_analyze() {
    local dir="$1"
    _repo_scan "$dir"
    _repo_deps "$dir"
    _repo_build_model "$dir"
}

# Get a summary of the project for agent context
repo_summary() {
    local dir="$1"
    local model="$dir/$COUNCIL_DIR/project_model.json"
    [[ ! -f "$model" ]] && echo "No project model available." && return

    require_jq
    local langs frameworks total_files
    langs="$(jq -r '[.languages[].name] | join(", ")' "$model")"
    frameworks="$(jq -r '.frameworks | join(", ")' "$model")"
    total_files="$(jq -r '.total_files' "$model")"

    local is_greenfield
    is_greenfield="$(jq -r '.greenfield // false' "$model")"

    if [[ "$is_greenfield" == "true" ]]; then
        local intended_lang intended_fw proj_desc
        intended_lang="$(jq -r '.intended_language // "not specified"' "$model")"
        intended_fw="$(jq -r '.intended_framework // "none"' "$model")"
        proj_desc="$(jq -r '.project_description // "not specified"' "$model")"
        cat <<EOF
Project: $(basename "$dir") [GREENFIELD]
Root: $dir
Type: New project
Language: $intended_lang
Framework: $intended_fw
Description: $proj_desc

This is a new project. You are responsible for creating the initial project structure,
including scaffolding, dependency manifests, entry points, and configuration files.
Follow best practices and idiomatic conventions for the chosen language and framework.
EOF
    else
        cat <<EOF
Project: $(basename "$dir")
Root: $dir
Files: $total_files
Languages: ${langs:-unknown}
Frameworks: ${frameworks:-none detected}
Build: $(jq -r '.build_command // "unknown"' "$model")
Test: $(jq -r '.test_command // "unknown"' "$model")
EOF
    fi
}
