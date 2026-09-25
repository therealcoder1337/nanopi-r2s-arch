# SPDX-License-Identifier: GPL-2.0-or-later
# Trusted Firmware-A BL31 build for the mainline U-Boot Rockchip path.

run_git_tfa() {
    git -C "$TFA_DIR" -c safe.directory="$TFA_DIR" "$@"
}

checkout_tfa_ref() {
    run_git_tfa fetch --depth 1 origin "$TFA_REF"
    run_git_tfa checkout --detach FETCH_HEAD >/dev/null
    run_git_tfa reset --hard FETCH_HEAD >/dev/null
    run_git_tfa clean -fdx >/dev/null
}

fetch_tfa_tree() {
    local head
    if [ -d "$TFA_DIR/.git" ]; then
        head=$(run_git_tfa rev-parse -q HEAD 2>/dev/null) || head=
        if [ "$head" != "$TFA_COMMIT" ]; then
            echo "    → Updating TF-A to $TFA_REF (${TFA_COMMIT:0:12})..."
            checkout_tfa_ref
        else
            echo "    → Using cached TF-A: $TFA_DIR"
            run_git_tfa reset --hard HEAD >/dev/null
            run_git_tfa clean -fdx >/dev/null
        fi
    else
        echo "    → Cloning TF-A $TFA_REF..."
        git clone --depth 1 --branch "$TFA_REF" "$TFA_GIT_URL" "$TFA_DIR"
    fi

    head=$(run_git_tfa rev-parse -q HEAD)
    if [ "$head" != "$TFA_COMMIT" ]; then
        echo "Error: TF-A HEAD is ${head:0:12}, expected ${TFA_COMMIT:0:12}." >&2
        exit 1
    fi
}

get_tfa_build_tag() {
    {
        printf '%s\n' "$TFA_COMMIT" "$TFA_BUILD_TYPE"
        sha256sum "$SCRIPTS_DIR/trusted-firmware.sh"
    } | sha256sum | awk '{print $1}'
}

has_current_tfa_bl31() {
    local tag_file="$TFA_OUTPUT_DIR/.build-tag"
    [ -f "$TFA_BL31" ] \
        && [ -f "$tag_file" ] \
        && [ "$(cat "$tag_file")" = "$(get_tfa_build_tag)" ]
}

verify_tfa_bl31() {
    local bl31="$1"
    local entry loads

    entry=$(readelf -h "$bl31" | awk '/Entry point address:/ {print tolower($4); exit}')
    if [ "$entry" != "0x40000" ]; then
        echo "Error: BL31 entry point is ${entry:-none}, expected 0x40000" >&2
        exit 1
    fi

    loads=$(readelf -lW "$bl31" | awk '$1 == "LOAD" {n++} END {print n+0}')
    if [ "$loads" -lt 1 ]; then
        echo "Error: BL31 has no PT_LOAD segments" >&2
        exit 1
    fi
    echo "    BL31 OK."
}

build_trusted_firmware() {
    echo "[2/10] Trusted Firmware-A ($TFA_REF, $TFA_BUILD_TYPE)..."
    fetch_tfa_tree

    if [ "$SHOULD_SKIP_TFA_REBUILD" = 1 ] && has_current_tfa_bl31; then
        echo "    → Skipping TF-A rebuild (SHOULD_SKIP_TFA_REBUILD=1)"
        verify_tfa_bl31 "$TFA_BL31"
        return 0
    fi

    local variant="$TFA_BUILD_TYPE" debug built_bl31
    case "$variant" in
        debug) debug=1 ;;
        release) debug=0 ;;
        *)
            echo "Error: TFA_BUILD_TYPE must be debug or release" >&2
            exit 1
            ;;
    esac
    built_bl31="$TFA_DIR/build/rk3328/$variant/bl31/bl31.elf"

    echo "    → Building BL31..."
    rm -rf "$TFA_DIR/build/rk3328/$variant"
    make -C "$TFA_DIR" -j"$BUILD_JOBS" CROSS_COMPILE=aarch64-linux-gnu- \
        PLAT=rk3328 DEBUG="$debug" bl31

    if [ ! -f "$built_bl31" ]; then
        echo "Error: BL31 was not produced: $built_bl31" >&2
        exit 1
    fi

    install -m 0644 "$built_bl31" "$TFA_BL31"
    verify_tfa_bl31 "$TFA_BL31"
    get_tfa_build_tag > "$TFA_OUTPUT_DIR/.build-tag"
}
