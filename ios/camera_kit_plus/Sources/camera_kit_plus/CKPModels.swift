// CKPModels.swift
// Shared models for CameraKitPlus

import Foundation
import CoreGraphics

// MARK: - Codable wrappers for CoreGraphics (safe to send over channel)

public struct CornerPointModel: Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CKPPoint: Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ p: CGPoint) { self.x = Double(p.x); self.y = Double(p.y) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct CKPRect: Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ r: CGRect) {
        self.x = Double(r.origin.x)
        self.y = Double(r.origin.y)
        self.width = Double(r.size.width)
        self.height = Double(r.size.height)
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

// MARK: - Barcode payload used by Flutter side

public struct CKPBarcodeData: Codable {
    public var value: String?
    public var type: Int?
    public var cornerPoints: [CKPPoint]

    public init(value: String?, type: Int?, cornerPoints: [CKPPoint]) {
        self.value = value
        self.type = type
        self.cornerPoints = cornerPoints
    }
}

// MARK: - (Optional) OCR line model (make it Codable-friendly)

public struct CKPLineModel: Codable {
    public var text: String
    public var confidence: Double?
    public var boundingBox: CKPRect?         // use CKPRect instead of CGRect
    public var cornerPoints: [CKPPoint]?     // use CKPPoint instead of CGPoint

    public init(text: String,
                confidence: Double? = nil,
                boundingBox: CKPRect? = nil,
                cornerPoints: [CKPPoint]? = nil) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.cornerPoints = cornerPoints
    }
}

class OcrData: Codable {
    var text: String
    var path: String?
    var orientation: Int?
    var lines: [LineModel]

    init(text: String, path: String?, orientation: Int?, lines: [LineModel]) {
        self.text = text
        self.path = path
        self.orientation = orientation
        self.lines = lines
    }
}

class LineModel: Codable {
    var text: String
    var cornerPoints: [CornerPointModel] = []

    init(text: String = "", cornerPoints: [CornerPointModel] = []) {
        self.text = text
        self.cornerPoints = cornerPoints
    }
}
