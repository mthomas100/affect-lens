"""Convert Microsoft FER+ ONNX (emotion-ferplus-8) to a Core ML classifier.

Pipeline: ONNX -> (opset upgrade if needed) -> onnx2torch -> softmax wrapper
-> torch.jit.trace -> coremltools mlprogram classifier with embedded labels.

Output: FERPlus.mlpackage — 64x64 grayscale face in (0-255), 8 labeled
probabilities out. Labels use FER+ canonical order but are EMBEDDED, so
consumers can match by name instead of index.
"""

import sys

import numpy as np
import onnx
import torch
import torch.nn as nn
from onnx import version_converter

import coremltools as ct
import onnx2torch

SRC = "emotion-ferplus-8.onnx"
DST = "FERPlus.mlpackage"
LABELS = ["neutral", "happiness", "surprise", "sadness", "anger", "disgust", "fear", "contempt"]

model = onnx.load(SRC)
print("source opset:", [o.version for o in model.opset_import])


def materialize_auto_pads(m: onnx.ModelProto) -> onnx.ModelProto:
    """Rewrite SAME_UPPER/SAME_LOWER auto_pad into explicit pads.

    onnx2torch does not implement auto_pad. With a fixed input size we can
    shape-infer every intermediate tensor and compute the exact pads.
    """
    m = onnx.shape_inference.infer_shapes(m)
    shapes = {}
    for vi in list(m.graph.value_info) + list(m.graph.input) + list(m.graph.output):
        dims = [d.dim_value for d in vi.type.tensor_type.shape.dim]
        shapes[vi.name] = dims

    patched = 0
    for node in m.graph.node:
        if node.op_type not in ("Conv", "MaxPool", "AveragePool"):
            continue
        attrs = {a.name: a for a in node.attribute}
        ap = attrs.get("auto_pad")
        apv = ap.s.decode() if ap is not None else "NOTSET"
        if apv not in ("SAME_UPPER", "SAME_LOWER"):
            continue
        in_shape = shapes.get(node.input[0])
        assert in_shape and all(d > 0 for d in in_shape[2:]), f"no static shape for {node.name}"
        kernel = list(attrs["kernel_shape"].ints)
        strides = list(attrs["strides"].ints) if "strides" in attrs else [1] * len(kernel)
        begin, end = [], []
        for size, k, s in zip(in_shape[2:], kernel, strides):
            out = -(-size // s)  # ceil division
            total = max((out - 1) * s + k - size, 0)
            b = total // 2
            e = total - b
            if apv == "SAME_LOWER":
                b, e = e, b
            begin.append(b)
            end.append(e)
        node.attribute.remove(ap)
        for a in list(node.attribute):
            if a.name == "pads":
                node.attribute.remove(a)
        node.attribute.append(onnx.helper.make_attribute("pads", begin + end))
        patched += 1
    print(f"materialized pads on {patched} nodes")
    return m


model = materialize_auto_pads(model)

try:
    torch_model = onnx2torch.convert(model)
    print("onnx2torch: direct conversion ok")
except Exception as e:  # old opset — upgrade and retry
    print("direct conversion failed (%s); upgrading opset to 13" % e)
    model = version_converter.convert_version(model, 13)
    torch_model = onnx2torch.convert(model)
    print("onnx2torch: conversion ok after opset upgrade")


class SoftmaxWrapped(nn.Module):
    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, x):
        return torch.softmax(self.base(x), dim=1)


wrapped = SoftmaxWrapped(torch_model).eval()
example = torch.rand(1, 1, 64, 64) * 255.0

with torch.no_grad():
    sanity = wrapped(example)
print("torch output shape:", tuple(sanity.shape), "sum:", float(sanity.sum()))
assert sanity.shape == (1, 8)
assert abs(float(sanity.sum()) - 1.0) < 1e-4

traced = torch.jit.trace(wrapped, example)

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.ImageType(
            name="face",
            shape=(1, 1, 64, 64),
            color_layout=ct.colorlayout.GRAYSCALE,
            scale=1.0,
            bias=0.0,
        )
    ],
    classifier_config=ct.ClassifierConfig(LABELS),
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
)
mlmodel.short_description = (
    "FER+ facial expression classifier (Microsoft FERPlus, MIT license). "
    "Input: 64x64 grayscale face, raw 0-255. Output: 8 emotion probabilities."
)
mlmodel.save(DST)
print("saved", DST)

# Round-trip sanity check through Core ML itself.
from PIL import Image

reloaded = ct.models.MLModel(DST)
img = Image.fromarray((np.random.rand(64, 64) * 255).astype("uint8"), mode="L")
out = reloaded.predict({"face": img})
probs_key = [k for k in out if isinstance(out[k], dict)][0]
probs = out[probs_key]
total = sum(probs.values())
print("coreml labels:", sorted(probs.keys()))
print("coreml prob sum:", total, "| top:", max(probs, key=probs.get))
assert set(probs.keys()) == set(LABELS), "label mismatch"
assert abs(total - 1.0) < 1e-3, "probabilities do not sum to 1"
print("SANITY OK")
