// Defaults of this Firefox for Pywalfox (apps/org.mozilla.firefox).
// about:config still changes them.

// Native messaging through Firefox's own manifest lookup: ~/.mozilla in the
// sandbox, where /app/libexec/firefox-prestart installs /app/bin/pywalfox. With
// the XDG portal or xdg-native-messaging-proxy enabled, Firefox asks only them
// and finds no host in the sandbox. Both are off by default; this keeps them off.
pref("widget.use-xdg-desktop-portal.native-messaging", 0);
pref("widget.use-xdg-desktop-portal.native-messaging-proxy", 0);

// Pywalfox's custom CSS (extension settings, "Custom CSS") writes userChrome.css
// and userContent.css into the profile; Firefox reads them only with this.
pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
