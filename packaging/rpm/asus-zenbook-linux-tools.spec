Name:           asus-zenbook-linux-tools
Version:        %{version}
Release:        1%{?dist}
Summary:        ASUS ZenBook hardware helpers for Linux
License:        MIT
URL:            https://github.com/ventura8/asus-zenbook-linux-tools
BuildArch:      noarch

BuildRequires:  gettext
BuildRequires:  /usr/bin/bash

Requires:       python3
Requires:       alsa-utils
Requires:       gettext

%if 0%{?fedora}
Requires:       python3-evdev >= 1.6.0
Requires:       python3-dbus
Requires:       python3-gobject
Recommends:     ydotool
Recommends:     alsa-tools
Recommends:     xdotool
Recommends:     wmctrl
Recommends:     power-profiles-daemon
%endif

%if 0%{?rhel} || 0%{?rocky} || 0%{?almalinux}
Requires:       python3-dbus
Requires:       python3-gobject
Recommends:     xdotool
Recommends:     wmctrl
Recommends:     power-profiles-daemon
%endif

%if 0%{?suse_version}
Requires:       python313-evdev
Requires:       python313-dbus-python
Requires:       python313-gobject
Requires:       gettext-tools
Requires:       hda-verb
Recommends:     ydotool
Recommends:     xdotool
Recommends:     wmctrl
Recommends:     power-profiles-daemon
%endif

%description
Lightweight evdev daemons, audio amp initialization, ScreenPad helpers,
and touchpad Share gestures for ASUS ZenBook laptops.
After install, run asus-zenbook-configure to select components interactively.

%prep
# Checkout build: sources live under %{_gitroot}.

%build
# Native Python/shell package — no compile step.

%install
rm -rf %{buildroot}
%{_gitroot}/packaging/stage-payload.sh %{buildroot}

%files
/usr/share/asus-zenbook-linux-tools/
/usr/sbin/asus-zenbook-configure
/usr/share/locale/*/LC_MESSAGES/asus-zenbook-linux-tools.mo

%define _asus_state_dir /var/lib/asus-zenbook-linux-tools

%post
. /usr/share/asus-zenbook-linux-tools/packaging/scriptlets/configure-common.sh
if [ "$1" -eq 1 ]; then
    _asus_configure_after_install ""
else
    _asus_daemon_reload_if_live
fi

%preun
if [ "$1" -eq 0 ]; then
    . /usr/share/asus-zenbook-linux-tools/packaging/scriptlets/configure-common.sh
    _asus_run_packaged_uninstall || exit 1
fi

%postun
if [ "$1" -eq 0 ]; then
    rm -rf %{_asus_state_dir}
fi

%changelog
* Wed Aug 19 2026 ventura8 <alexandrescu.sergiu@gmail.com> - 1.0.3-1
- Initial multi-distro RPM packaging for ASUS ZenBook Linux Tools v1.0.3.
