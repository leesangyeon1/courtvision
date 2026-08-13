#!/usr/bin/env python3
"""Per-class eval for a YOLO checkpoint — the fixed-val-set gate.

ultralytics computes everything (per-class P/R/AP + confusion matrix);
this wrapper just prints the per-class table the mAP mean hides.

Usage:
    .venv/bin/python tools/eval_model.py runs/detect/runs/eagleeye/weights/best.pt DS/data.yaml
"""
import argparse

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", help="path to .pt checkpoint")
    parser.add_argument("data", help="path to data.yaml (fixed val set)")
    parser.add_argument("--imgsz", type=int, default=640)
    args = parser.parse_args()

    results = YOLO(args.model).val(data=args.data, imgsz=args.imgsz)
    box = results.box
    print(f"\n{'class':<24}{'P':>8}{'R':>8}{'AP50':>8}{'AP':>8}")
    for i, class_index in enumerate(box.ap_class_index):
        name = results.names[int(class_index)]
        print(f"{name:<24}{box.p[i]:>8.3f}{box.r[i]:>8.3f}"
              f"{box.ap50[i]:>8.3f}{box.ap[i]:>8.3f}")
    print(f"\nmAP50 {box.map50:.3f}  mAP50-95 {box.map:.3f}")
    print(f"confusion matrix + plots: {results.save_dir}")


if __name__ == "__main__":
    main()
