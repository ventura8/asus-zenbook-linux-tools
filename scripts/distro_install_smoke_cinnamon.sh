#!/usr/bin/env bash
# Sourced by distro_install_smoke_desktop.sh — Cinnamon DESKTOP configure asserts.

_SMOKE_CINNAMON_ORIG_LIST="['other-custom']"
_SMOKE_CINNAMON_ORIG_VIDEO="['XF86Display']"

_smoke_write_cinnamon_stubs() {
    local mock_bin="$1" gset_log="$2"
    printf '%s\n' "$_SMOKE_CINNAMON_ORIG_LIST" > "${gset_log}.val.custom-list"
    printf '%s\n' "$_SMOKE_CINNAMON_ORIG_VIDEO" > "${gset_log}.val.video-outputs"
    cat > "$mock_bin/gsettings" <<EOF
#!/bin/sh
log="$gset_log"
printf '%s\\n' "\$*" >> "\$log"
case "\$1" in
  list-keys)
    printf '%s\\n' custom-list video-outputs
    exit 0
    ;;
  get)
    key="\$3"
    case "\$2" in
      *:*) key="\${2##*/}_\${3}" ;;
    esac
    if [ -f "\${log}.val.\${key}" ]; then
      cat "\${log}.val.\${key}"
    elif [ -f "\${log}.val.\$3" ]; then
      cat "\${log}.val.\$3"
    else
      echo "[]"
    fi
    exit 0
    ;;
  set)
    key="\$3"
    case "\$2" in
      *:*) key="\${2##*/}_\${3}" ;;
    esac
    printf '%s\\n' "\$4" > "\${log}.val.\${key}"
    printf '%s\\n' "\$4" > "\${log}.val.\$3"
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

_smoke_assert_cinnamon_installed() {
    local dest="$1" uid="$2" gset_log="$3"
    local state_dir
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_assert_family_marker "$state_dir" cinnamon
    _smoke_require_file "$state_dir/orig_cinnamon_custom_list" \
        "Cinnamon custom-list backup missing"
    _smoke_require_grep "asus-display-mode" "$gset_log" \
        "Cinnamon custom-list was not updated"
    _smoke_require_grep "asus-control-center" "$gset_log" \
        "Cinnamon control-center slot missing"
    _smoke_require_grep "asus-screenshot" "$gset_log" \
        "Cinnamon screenshot slot missing"
}

_smoke_assert_cinnamon_uninstalled() {
    local dest="$1" uid="$2" gset_log="$3"
    local state_dir
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    _smoke_assert_marker_cleared "$state_dir" Cinnamon
    _smoke_assert_file_eq "${gset_log}.val.custom-list" "$_SMOKE_CINNAMON_ORIG_LIST" \
        "Cinnamon custom-list"
    _smoke_assert_file_eq "${gset_log}.val.video-outputs" "$_SMOKE_CINNAMON_ORIG_VIDEO" \
        "Cinnamon video-outputs"
}
