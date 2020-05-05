import 'dart:async';
import 'dart:io';

import 'package:Okuna/plugins/share/share.dart';
import 'package:Okuna/services/localization.dart';
import 'package:Okuna/services/toast.dart';
import 'package:Okuna/services/validation.dart';
import 'package:async/async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media.dart';

class ShareService {
  static const _stream = const EventChannel('openbook.social/receive_share');

  ToastService _toastService;
  MediaService _mediaService;
  ValidationService _validationService;
  LocalizationService _localizationService;

  StreamSubscription _shareReceiveSubscription;
  List<Future<dynamic> Function({String text, File image, File video})>
      _subscribers;

  Share _queuedShare;
  bool _isProcessingShare = false;
  Map<Share, ShareOperation> _activeShares;

  BuildContext _context;

  ShareService() {
    _subscribers = [];
    _activeShares = {};

    if (Platform.isAndroid) {
      if (_shareReceiveSubscription == null) {
        _shareReceiveSubscription =
            _stream.receiveBroadcastStream().listen(_onReceiveShare);
      }
    }
  }

  void setToastService(ToastService toastService) {
    _toastService = toastService;
  }

  void setValidationService(ValidationService validationService) {
    _validationService = validationService;
  }

  void setLocalizationService(LocalizationService localizationService) {
    _localizationService = localizationService;
  }

  void setMediaService(MediaService mediaService) {
    _mediaService = mediaService;
  }

  void setContext(BuildContext context) {
    _context = context;
  }

  /// Subscribe to share events.
  ///
  /// [onShare] should return [true] if it consumes the share immediately,
  /// a [CancelableOperation] if some amount of work has to be done first (like
  /// gif to video conversion in OBSavePostModal), or [false] if the subscriber
  /// did _not_ consume the share (the share will be passed on to the next subscriber).
  ///
  /// If a [CancelableOperation] is returned, it _must_ handle cancellation
  /// properly.
  void subscribe(
      Future<dynamic> Function({String text, File image, File video}) onShare) {
    _subscribers.add(onShare);

    if (_subscribers.length == 1) {
      _processQueuedShare();
    }
  }

  void unsubscribe(
      Future<dynamic> Function({String text, File image, File video})
          subscriber) {
    _subscribers.remove(subscriber);
  }

  void _onReceiveShare(dynamic shared) async {
    _queuedShare = Share.fromReceived(shared);

    if (_subscribers.isNotEmpty && !_isProcessingShare) {
      _processQueuedShare();
    }
  }

  Future<void> _processQueuedShare() async {
    if (_queuedShare != null) {
      // Schedule cancellation of existing share operations. We don't cancel
      // immediately since that can cause concurrent modification of _activeShares.
      _activeShares
          .forEach((key, value) => Future.delayed(Duration(), value.cancel));

      var share = _queuedShare;
      _queuedShare = null;

      _isProcessingShare = true;
      var operation = CancelableOperation.fromFuture(_onShare(share));
      _activeShares[share] = ShareOperation(share, operation);
      _activeShares[share].then(() => _activeShares.remove(share));
      _isProcessingShare = false;

      // Recurse since a new share might have came in while the last was being processed.
      _processQueuedShare();
    }
  }

  Future<void> _onShare(Share share) async {
    String text;
    File image;
    File video;

    if (share.error != null) {
      _toastService.error(
          message: _localizationService.trans(share.error), context: _context);
      if (share.error.contains('uri_scheme')) {
        throw share.error;
      }
      return;
    }

    if (share.image != null) {
      image = File.fromUri(Uri.parse(share.image));
      image = await _mediaService.fixExifRotation(image);
      image = await _mediaService.processImage(image);
      if (!await _validationService.isImageAllowedSize(
          image, OBImageType.post)) {
        _showFileTooLargeToast(
            _validationService.getAllowedImageSize(OBImageType.post));
        return;
      }
    }

    if (share.video != null) {
      video = File.fromUri(Uri.parse(share.video));

      if (!await _validationService.isVideoAllowedSize(video)) {
        _showFileTooLargeToast(_validationService.getAllowedVideoSize());
        return;
      }

      if (await _mediaService.isGif(video)) {
        Completer<File> completer = Completer();
        _mediaService
            .convertGifToVideo(video)
            .then((file) => completer.complete(file), onError: (error, trace) {
          print(error);
          _toastService.error(
              message: _localizationService.error__unknown_error,
              context: _context);
        });
        video = await completer.future;
      }
    }

    if (share.text != null) {
      text = share.text;
      if (!_validationService.isPostTextAllowedLength(text)) {
        _toastService.error(
            message:
                'Text too long (limit: ${ValidationService.POST_MAX_LENGTH} characters)',
            context: _context);
        return;
      }
    }

    for (var sub in _subscribers.reversed) {
      if (_activeShares[share].isCancelled) {
        break;
      }

      var subResult = await sub(text: text, image: image, video: video);

      // Stop event propagation if we have a sub-result that is either true or
      // a CancelableOperation.
      if (subResult is CancelableOperation) {
        _activeShares[share].setSubOperation(subResult);
        break;
      } else if (subResult == true) {
        break;
      }
    }
  }

  Future _showFileTooLargeToast(int limitInBytes) async {
    _toastService.error(
        message: _localizationService
            .image_picker__error_too_large(limitInBytes ~/ 1048576),
        context: _context);
  }
}

class ShareOperation {
  Share share;
  CancelableOperation shareOperation;
  CancelableOperation subOperation;
  bool isCancelled = false;

  bool _shareComplete = false;
  bool _subComplete = false;
  FutureOr Function() _callback;

  ShareOperation(this.share, this.shareOperation) {
    shareOperation.then((_) {
      _shareComplete = true;
      _complete();
    });
  }

  void setSubOperation(CancelableOperation operation) {
    subOperation = operation;
    subOperation.then((_) {
      _subComplete = true;
      _complete();
    });

    shareOperation.then((_) {
      if (shareOperation.isCanceled) {
        subOperation.cancel();
      }
    });
  }

  void cancel() {
    isCancelled = true;
    shareOperation?.cancel();
    subOperation?.cancel();
  }

  void then(FutureOr Function() callback) {
    _callback = callback;
  }

  void _complete() {
    if ((subOperation == null || _subComplete) &&
        (shareOperation == null || _shareComplete)) {
      _callback();
    }
  }
}
