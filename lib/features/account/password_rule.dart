import 'dart:convert';

/// The server's rule for a new password: at least 12 characters, at most 128
/// bytes. Characters are runes, so an emoji counts once; the server counts
/// after NFC, which never yields more characters than typed.
bool newPasswordOk(String password) =>
    password.runes.length >= 12 && utf8.encode(password).length <= 128;
