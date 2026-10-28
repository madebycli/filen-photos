import "dart:io";

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_account.dart';
import "package:photos/models/base/id.dart";

class EnteRequestInterceptor extends Interceptor {
  final String enteEndpoint;
  final String id = Platform.isIOS ? "ios" : "droid";

  EnteRequestInterceptor(this.enteEndpoint);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (kDebugMode) {
      assert(
        options.baseUrl == enteEndpoint,
        "interceptor should only be used for API endpoint",
      );
    }
    // Filen fork: a Filen account never talks to Ente's API. Reject locally so nothing leaves the
    // device; callers see a cancelled request.
    if (FilenAccount.isActive) {
      return handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: StateError("Ente API access is disabled for Filen accounts"),
        ),
        true,
      );
    }
    // ignore: prefer_const_constructors
    options.headers.putIfAbsent("x-request-id", () => newID(id));
    final String? tokenValue = Configuration.instance.getToken();
    if (tokenValue != null) {
      options.headers.putIfAbsent("X-Auth-Token", () => tokenValue);
    }
    return super.onRequest(options, handler);
  }
}
