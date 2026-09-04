## 0.0.50

* iOS OCR: Apple Vision instead of Google ML Kit; SPM layout under `ios/camera_kit_plus/`.
* Per-view MethodChannels (`camera_kit_plus/view_$id`) so barcode/OCR controllers bind to the live platform view.
* Vision OCR: main-thread callbacks, wide camera preferred, `.accurate` + `en-US` for live frames.
* Delete dead Android/iOS leftovers; fix double method replies, OCR macro AF, permissions, dispose.
* Example app rewritten with barcode/OCR toggle and camera controls.
* Remove unused `permission_handler` dependency from the plugin (hosts may still use it).

## 0.0.1

* Initial release.
