import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/auth_api.dart';
import '../../core/json.dart';
import '../../core/pkce.dart';
import '../../core/strings.dart';

enum SignInOutcome { success, ignored, failed }

class SignInResult {
  const SignInResult(this.outcome, {this.message});
  final SignInOutcome outcome;

  /// The server's or client's reason, set when [outcome] is failed.
  final String? message;
}

/// The one sign-in waiting for its browser callback. Memory only.
class PendingSignIn {
  const PendingSignIn({
    required this.serverUrl,
    required this.verifier,
    required this.state,
    required this.expiresAt,
  });
  final String serverUrl;
  final String verifier;
  final String state;
  final DateTime expiresAt;
}

/// Where `meshcorebeacon://` links come from; a seam so tests need no channel.
abstract class LinkSource {
  Future<Uri?> initialLink();
  Stream<Uri> get links;
}

class AppLinksSource implements LinkSource {
  AppLinksSource([AppLinks? links]) : _links = links ?? AppLinks();
  final AppLinks _links;
  @override
  Future<Uri?> initialLink() => _links.getInitialLink();
  @override
  Stream<Uri> get links => _links.uriLinkStream;
}

/// Browser sign-in with PKCE: opens the web page, then trades the code the
/// callback link carries for a session token.
class SignInFlow extends ChangeNotifier {
  SignInFlow({
    required this.apiFor,
    required this.launch,
    required this.now,
    this.accountFor,
    this.random,
  });
  final AuthApi Function(String serverUrl) apiFor;
  final Future<bool> Function(Uri) launch;
  final DateTime Function() now;

  /// The account state of a server's screens, or null when it is not active.
  final AccountState? Function(String serverUrl)? accountFor;
  final Random? random;

  static const lifetime = Duration(minutes: 10);
  static const _scheme = 'meshcorebeacon';
  static const _host = 'auth';

  PendingSignIn? pending;
  String? _used;

  /// The latest success or failure, for the account section to show.
  SignInResult? lastResult;

  /// Opens the browser. A new call replaces any sign-in still waiting.
  Future<void> start(String serverUrl) async {
    final next = PendingSignIn(
      serverUrl: serverUrl,
      verifier: randomToken(32, random),
      state: randomToken(16, random),
      expiresAt: now().add(lifetime),
    );
    pending = next;
    apiFor(serverUrl).supersedeSignIn();
    final base = Uri.parse(serverUrl);
    final url = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/',
      queryParameters: {
        ...base.queryParameters,
        'view': 'signin',
        'app': '1',
        'code_challenge': pkceChallenge(next.verifier),
        'state': next.state,
      },
    );
    var opened = false;
    try {
      opened = await launch(url);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      if (identical(pending, next)) pending = null;
      throw ApiException(trKey('account.browserFailed'));
    }
  }

  Future<SignInResult> handleCallback(Uri link) async {
    const ignored = SignInResult(SignInOutcome.ignored);
    if (link.scheme != _scheme || link.host != _host) return ignored;
    // The exchange is refused; the account section says why.
    SignInResult reject() {
      final result = SignInResult(
        SignInOutcome.failed,
        message: trKey('account.callbackRejected'),
      );
      lastResult = result;
      notifyListeners();
      return result;
    }

    final current = pending;
    // The same link delivered twice (cold start and stream) is not a new try.
    if (current == null) {
      return _used == link.queryParameters['state'] ? ignored : reject();
    }
    if (!now().isBefore(current.expiresAt)) {
      pending = null;
      return reject();
    }
    final code = link.queryParameters['code'];
    final state = link.queryParameters['state'];
    if (code == null || code.isEmpty || state == null) return ignored;
    if (!constantTimeEquals(state, current.state)) return reject();
    // One try per sign-in: a repeat of the same link finds nothing pending.
    pending = null;
    _used = state;
    SignInResult result;
    try {
      final reply = await apiFor(current.serverUrl)
          .exchangeAppCode(code, current.verifier);
      accountFor?.call(current.serverUrl)?.adopt(object(reply['user']));
      result = const SignInResult(SignInOutcome.success);
    } on SignInSuperseded {
      return ignored;
    } on ApiException catch (e) {
      result = SignInResult(
        SignInOutcome.failed,
        // A busy server is retryable and reads the same in every language.
        message: e.code == 'service_unavailable'
            ? trKey('serverText.errors.busy')
            : e.message,
      );
    } catch (_) {
      // A keystore that cannot save the token also leaves us signed out.
      result = SignInResult(
        SignInOutcome.failed,
        message: trKey('account.saveFailed'),
      );
    }
    lastResult = result;
    notifyListeners();
    return result;
  }
}

/// Feeds the cold-start link and later links into [SignInFlow].
class SignInLinks {
  SignInLinks(this.flow, this.source);
  final SignInFlow flow;
  final LinkSource source;
  StreamSubscription<Uri>? _subscription;

  Future<void> listen() async {
    _subscription = source.links.listen(flow.handleCallback);
    try {
      final initial = await source.initialLink();
      if (initial != null) await flow.handleCallback(initial);
    } catch (_) {
      // No link plugin on this platform: sign-in is simply unavailable.
    }
  }

  Future<void> dispose() async => _subscription?.cancel();
}

/// Hands the flow to screens below the app root.
class SignInScope extends InheritedNotifier<SignInFlow> {
  const SignInScope({super.key, required SignInFlow flow, required super.child})
    : super(notifier: flow);

  static SignInFlow? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SignInScope>()?.notifier;
}
