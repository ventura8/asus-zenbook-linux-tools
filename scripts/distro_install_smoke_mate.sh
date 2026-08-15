#!/usr/bin/env bash
# Sourced by distro_install_smoke_desktop.sh — MATE DESKTOP configure asserts.

_smoke_write_mate_stubs() {
    local mock_bin="$1" gset_log="$2"
    cat > "$mock_bin/gsettings" <<EOF
#!/bin/sh
log="$gset_log"
printf '%s\\n' "\$*" >> "\$log"
case "\$1" in
  list-keys)
    printf '%s\\n' name action binding
    exit 0
    ;;
  get)
    # Absent slots fail so install marks .absent backups.
    exit 1
    ;;
  set)
    key="\$3"
    case "\$2" in
      *:*)
        slot=\$(printf '%s' "\$2" | sed 's|.*/keybindings/||;s|/$||')
        key="\${slot}_\${3}"
        ;;
    esac
    printf '%s\\n' "\$4" > "\${log}.val.\${key}"
    exit 0
    ;;
  reset-recursively)
    exit 0
    ;;
esac
exit 0
EOF
    chmod +x "$mock_bin/gsettings"
}

_smoke_assert_mate_installed() {
    local dest="$1" uid="$2" gset_log="$3"
    local state_dir
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_assert_family_marker "$state_dir" mate
    if [ ! -f "$state_dir/orig_mate_xf86display" ]; then
        _smoke_require_file "$state_dir/orig_mate_xf86display.absent" \
            "MATE XF86Display backup missing"
    fi
    _smoke_require_grep "asus-display-mode" "$gset_log" \
        "MATE display-mode binding missing"
    _smoke_require_grep "asus-control-center" "$gset_log" \
        "MATE control-center binding missing"
    _smoke_require_grep "asus-screenshot" "$gset_log" \
        "MATE screenshot binding missing"
}

_smoke_assert_mate_uninstalled() {
    local dest="$1" uid="$2" _gset_log="$3"
    local state_dir
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_assert_marker_cleared "$state_dir" MATE
}
