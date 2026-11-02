// Defaults of this Firefox (apps/org.mozilla.firefox), those Mozilla's own
// Flatpak sets in its distribution.ini; about:config still changes them.
// That file also names the distribution: the tarball's own names Mozilla's
// official build (mozilla-official), which this is, unchanged, and stays.
// distribution/policies.json turns off what must stay off: updates (the
// app's come with the Flatpak) and the default-browser check (the host
// decides that).

// The host's language (LANG), among those Firefox has: with no language
// pack here, its own en-US. Settings, Language still picks another once
// one is installed.
pref("intl.locale.requested", "");

// The runtime's hunspell dictionaries (its en_US), beside Firefox's own
// en-US.
pref("spellchecker.dictionary_path", "/usr/share/hunspell");
