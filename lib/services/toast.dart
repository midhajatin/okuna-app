import 'package:Openbook/widgets/toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum ToastType { info, warning, success, error }

class ToastService {
  static const Duration toastDuration = Duration(seconds: 3);
  static Color colorError = Colors.redAccent;
  static Color colorSuccess = Colors.greenAccent[700];
  static Color colorInfo = Colors.blue;
  static Color colorWarning = Colors.yellow[800];

  void warning({
    String title,
    @required String message,
    @required BuildContext context,
    GlobalKey<ScaffoldState> scaffoldKey,
    VoidCallback onDismissed,
  }) {
    toast(
        title: title,
        message: message,
        type: ToastType.warning,
        context: context,
        onDismissed: onDismissed,
        scaffoldKey: scaffoldKey);
  }

  void success({
    String title,
    Widget child,
    @required String message,
    @required BuildContext context,
    GlobalKey<ScaffoldState> scaffoldKey,
    VoidCallback onDismissed,
  }) {
    toast(
        title: title,
        message: message,
        type: ToastType.success,
        context: context,
        child: child,
        onDismissed: onDismissed,
        scaffoldKey: scaffoldKey);
  }

  void error({
    String title,
    @required String message,
    @required BuildContext context,
    GlobalKey<ScaffoldState> scaffoldKey,
    VoidCallback onDismissed,
  }) {
    toast(
        title: title,
        message: message,
        type: ToastType.error,
        context: context,
        onDismissed: onDismissed,
        scaffoldKey: scaffoldKey);
  }

  void info({
    String title,
    Widget child,
    @required String message,
    @required BuildContext context,
    GlobalKey<ScaffoldState> scaffoldKey,
    VoidCallback onDismissed,
  }) {
    toast(
        title: title,
        child: child,
        message: message,
        type: ToastType.info,
        context: context,
        scaffoldKey: scaffoldKey,
        onDismissed: onDismissed);
  }

  void toast({
    String title,
    Widget child,
    @required String message,
    @required ToastType type,
    @required BuildContext context,
    GlobalKey<ScaffoldState> scaffoldKey,
    VoidCallback onDismissed,
  }) {
    if (context != null) {
      OpenbookToast.of(context).showToast(
          child: child,
          color: _getToastColor(type),
          message: message,
          onDismissed: onDismissed);
    } else {
      print('Context was null, cannot show toast');
    }
  }

  Color _getToastColor(ToastType type) {
    var color;

    switch (type) {
      case ToastType.error:
        color = colorError;
        break;
      case ToastType.info:
        color = colorInfo;
        break;
      case ToastType.success:
        color = colorSuccess;
        break;
      case ToastType.warning:
        color = colorWarning;
        break;
    }

    return color;
  }
}
