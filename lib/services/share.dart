import 'dart:async';
import 'dart:io';

import 'package:Okuna/plugins/share/share.dart' as SharePlugin;
import 'package:Okuna/services/localization.dart';
import 'package:Okuna/services/media/media.dart';
import 'package:Okuna/services/media/models/media_file.dart';
import 'package:Okuna/services/toast.dart';
import 'package:Okuna/services/validation.dart';
import 'package:async/async.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ShareService {
  static const _stream = const EventChannel('openbook.social/receive_share');

  ToastService _toastService;
  MediaService _mediaService;
  ValidationService _validationService;
  LocalizationService _localizationService;

  StreamSubscription _shareReceiveSubscription;
  List<ShareSubscriber> _subscribers;

  SharePlugin.Share _queuedShare;
  bool _isProcessingShare = false;
  Map<SharePlugin.Share, ShareOperation> _activeShares;

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
  /// [onShare] should a [CancelableOperation] if some amount of work has to be
  /// done first (like gif to video conversion in OBSavePostModal) to process
  /// the share, otherwise [null] is expected.
  ///
  /// If a [CancelableOperation] is returned, it _must_ handle cancellation
  /// properly.
  ShareSubscription subscribe({
    bool acceptsText = true,
    bool acceptsImages = true,
    bool acceptsVideos = true,
    @required Future<dynamic> Function(Share) onShare,
    void Function(MediaProcessingState state, {dynamic data}) onMediaProgress,
  }) {
    var subscriber = ShareSubscriber(
        acceptsText, acceptsImages, acceptsVideos, onShare, onMediaProgress);
    _subscribers.add(subscriber);

    if (_subscribers.length == 1) {
      _processQueuedShare();
    }

    return ShareSubscription(() => _subscribers.remove(subscriber));
  }

  void _onReceiveShare(dynamic shared) async {
    _queuedShare = SharePlugin.Share.fromReceived(shared);

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
      _activeShares[share] = ShareOperation(share, _onShare);
      _activeShares[share].then(() => _activeShares.remove(share));
      _activeShares[share].start();
      _isProcessingShare = false;

      // Recurse since a new share might have came in while the last was being processed.
      _processQueuedShare();
    }
  }

  Future<void> _onShare(SharePlugin.Share share) async {
    String text;
    File image;
    File video;

    // TODO(komposten)
    // 1) Find first sub who can handle the share.
    // 2) Ask for a media progress listener.
    // 3) Run normal operations down to the sub loop.
    // 4) Use the sub directly instead of the sub loop.

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
      var processedFile = await _mediaService.processMedia(
        media: MediaFile(image, FileType.image),
        context: _context,
      );
      image = processedFile.file;
    }

    if (share.video != null) {
      video = File.fromUri(Uri.parse(share.video));

      var processedFile = await _mediaService.processMedia(
        media: MediaFile(video, FileType.video),
        context: _context,
      );

      video = processedFile.file;
    }

    if (share.text != null) {
      text = share.text;
      if (!_validationService.isPostTextAllowedLength(text)) {
        String errorMessage =
            _localizationService.error__receive_share_text_too_long(
                ValidationService.POST_MAX_LENGTH);
        _toastService.error(message: errorMessage, context: _context);
        return;
      }
    }

    var newShare = Share(text: text, image: image, video: video);

    for (var sub in _subscribers.reversed) {
      if (_activeShares[share].isCancelled) {
        break;
      }

      var subResult = await sub.onShare(newShare);

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
}

class ShareOperation {
  final Future<void> Function(SharePlugin.Share) _shareFunction;

  SharePlugin.Share share;
  CancelableOperation shareOperation;
  CancelableOperation subOperation;
  bool isCancelled = false;

  bool _shareComplete = false;
  bool _subComplete = false;
  FutureOr Function() _callback;

  ShareOperation(this.share, Future<void> Function(SharePlugin.Share) shareFunction)
      : _shareFunction = shareFunction;

  void start() {
    shareOperation = CancelableOperation.fromFuture(_shareFunction(share));
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

class ShareSubscriber {
  final bool acceptsText;
  final bool acceptsImages;
  final bool acceptsVideos;
  final Future<dynamic> Function(Share) onShare;
  final void Function(MediaProcessingState, {dynamic data})
      mediaProgressCallback;

  const ShareSubscriber(this.acceptsText, this.acceptsImages,
      this.acceptsVideos, this.onShare, this.mediaProgressCallback);

  bool acceptsShare(SharePlugin.Share share) {
    return ((share.text == null || acceptsText) &&
        (share.image == null || acceptsImages) &&
        (share.video == null || acceptsVideos));
  }
}

class ShareSubscription {
  final VoidCallback _cancel;

  ShareSubscription(this._cancel);

  void cancel() {
    _cancel();
  }
}

class Share {
  final String text;
  final File image;
  final File video;

  const Share({this.text, this.image, this.video});
}