//
//  ViewController.swift
//  VideoCompressionTest
//
//  Created by Suren Gevorkyan on 3/16/20.
//  Copyright © 2020 Suren Gevorkyan. All rights reserved.
//

import UIKit
import Photos
import Foundation
import AVFoundation

class ViewController: UIViewController {
    @IBOutlet weak var thumbnailImageView: UIImageView!
    
    var url: URL?
    
    var assetWriter:AVAssetWriter?
    var assetReader:AVAssetReader?
    let bitrate:NSNumber = NSNumber(value:250000)
    
    @IBAction func selectVideoAction() {
        PHPhotoLibrary.requestAuthorization { (status) in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.showPicker()
                } else {
                    print("Unable to open library")
                }
            }
        }
    }
    
    private func processSelectedVideo() {
        guard let url = url, let newPath = FileManager.default.getPath() else { return }
        
        let originalSize = FileManager.default.fileSizeInBytes(path: url) / (1024 * 1024)
        print("$Original file size = \(originalSize) MB")
        
        convertVideoToLowQuailty(withInputURL: url, outputURL: newPath) { session in
            let compressedSize = FileManager.default.fileSizeInBytes(path: newPath)
            print("$File size after compressing = \(compressedSize  / (1024 * 1024)) MB OR \(compressedSize / 1024) KB")
        }
    }
    
    private func showPicker() {
        let imagePickerController = UIImagePickerController()
        imagePickerController.sourceType = .photoLibrary
        imagePickerController.delegate = self
        imagePickerController.mediaTypes = ["public.movie"]
        
        present(imagePickerController, animated: true, completion: nil)
    }
}

extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true, completion: nil)
        url = info[.mediaURL] as? URL
        processSelectedVideo()
    }
}

extension ViewController {
    func convertVideoToLowQuailty(withInputURL inputURL: URL?, outputURL: URL?, handler: @escaping (AVAssetExportSession?) -> Void) {
        do {
            if let outputURL = outputURL {
                try FileManager.default.removeItem(at: outputURL)
            }
        } catch {
        }
        var asset: AVURLAsset? = nil
        if let inputURL = inputURL {
            asset = AVURLAsset(url: inputURL, options: nil)
        }
        var exportSession: AVAssetExportSession? = nil
        if let asset = asset {
            exportSession = AVAssetExportSession(asset: asset, presetName:AVAssetExportPresetMediumQuality)
        }
        exportSession?.outputURL = outputURL
        exportSession?.outputFileType = .mov
        exportSession?.exportAsynchronously(completionHandler: {
            handler(exportSession)
        })
    }
    
    func compressFile(urlToCompress: URL, outputURL: URL, completion:@escaping (URL)->Void){
        //video file to make the asset

        var audioFinished = false
        var videoFinished = false

        let asset = AVAsset(url: urlToCompress);

        let duration = asset.duration
        let durationTime = CMTimeGetSeconds(duration)

        print("Video Actual Duration -- \(durationTime)")

        //create asset reader
        do{
            assetReader = try AVAssetReader(asset: asset)
        } catch{
            assetReader = nil
        }

        guard let reader = assetReader else{
            fatalError("Could not initalize asset reader probably failed its try catch")
        }

        let videoTrack = asset.tracks(withMediaType: AVMediaType.video).first!
        let audioTrack = asset.tracks(withMediaType: AVMediaType.audio).first!

        let videoReaderSettings: [String:Any] =  [(kCVPixelBufferPixelFormatTypeKey as String?)!:kCVPixelFormatType_32ARGB ]

        // ADJUST BIT RATE OF VIDEO HERE

        let videoSettings:[String:Any] = [
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey:self.bitrate],
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoHeightKey: videoTrack.naturalSize.height,
            AVVideoWidthKey: videoTrack.naturalSize.width
        ]


        let assetReaderVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        let assetReaderAudioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)


        if reader.canAdd(assetReaderVideoOutput){
            reader.add(assetReaderVideoOutput)
        }else{
            fatalError("Couldn't add video output reader")
        }

        if reader.canAdd(assetReaderAudioOutput){
            reader.add(assetReaderAudioOutput)
        }else{
            fatalError("Couldn't add audio output reader")
        }

        let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: nil)
        let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoReaderSettings)
        videoInput.transform = videoTrack.preferredTransform
        //we need to add samples to the video input

        let videoInputQueue = DispatchQueue(label: "videoQueue")
        let audioInputQueue = DispatchQueue(label: "audioQueue")

        do{
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: AVFileType.mov)
        }catch{
            assetWriter = nil
        }
        guard let writer = assetWriter else{
            fatalError("assetWriter was nil")
        }

        writer.shouldOptimizeForNetworkUse = true
        writer.add(videoInput)
        writer.add(audioInput)


        writer.startWriting()
        reader.startReading()
        writer.startSession(atSourceTime: CMTime.zero)


        let closeWriter:()->Void = {
            if (audioFinished && videoFinished){
                self.assetWriter?.finishWriting(completionHandler: {
                    print("------ Finish Video Compressing")
                    completion((self.assetWriter?.outputURL)!)
                })

                self.assetReader?.cancelReading()
            }
        }


        audioInput.requestMediaDataWhenReady(on: audioInputQueue) {
            while(audioInput.isReadyForMoreMediaData){
                let sample = assetReaderAudioOutput.copyNextSampleBuffer()
                if (sample != nil){
                    audioInput.append(sample!)
                }else{
                    audioInput.markAsFinished()
                    DispatchQueue.main.async {
                        audioFinished = true
                        closeWriter()
                    }
                    break;
                }
            }
        }

        videoInput.requestMediaDataWhenReady(on: videoInputQueue) {
            //request data here
            while(videoInput.isReadyForMoreMediaData){
                let sample = assetReaderVideoOutput.copyNextSampleBuffer()
                if (sample != nil){
                    let timeStamp = CMSampleBufferGetPresentationTimeStamp(sample!)
                    let timeSecond = CMTimeGetSeconds(timeStamp)
                    let per = timeSecond / durationTime
                    print("Duration --- \(per)")
                    videoInput.append(sample!)
                }else{
                    videoInput.markAsFinished()
                    DispatchQueue.main.async {
                        videoFinished = true
                        closeWriter()
                    }
                    break;
                }
            }
        }
    }
    
    
    
    func compress(videoPath : String, exportVideoPath : String, renderSize : CGSize, completion: @escaping (Bool) -> ()) {
        let videoUrl = URL(fileURLWithPath: videoPath)
        
        if !FileManager.default.fileExists(atPath: videoPath) {
            completion(false)
            return
        }
        
        let videoAssetUrl = AVURLAsset(url: videoUrl, options: nil)
        
        let videoTrackArray = videoAssetUrl.tracks(withMediaType: .video)
        
        if videoTrackArray.count < 1 {
            completion(false)
            return
        }
        
        let videoAssetTrack = videoTrackArray[0]
        
        let audioTrackArray = videoAssetUrl.tracks(withMediaType: .audio)
        
        if audioTrackArray.count < 1 {
            completion(false)
            return
        }
        
        let audioAssetTrack = audioTrackArray[0]
        
        // input readers
        let outputUrl = URL(fileURLWithPath: exportVideoPath)
        let videoWriter = try! AVAssetWriter(url: outputUrl, fileType: .mov)
        videoWriter.shouldOptimizeForNetworkUse = true
        
        let vSettings = videoSettings(size: renderSize)
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = videoAssetTrack.preferredTransform
        videoWriter.add(videoWriterInput)
        
//
//        let aSettings = audioSettings()
        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
//        audioWriterInput.expectsMediaDataInRealTime = false
//        audioWriterInput.transform = audioAssetTrack.preferredTransform
//        videoWriter.add(audioWriterInput)
        
        let videoReaderSettings : [String : Int] = [kCVPixelBufferPixelFormatTypeKey as String : Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoAssetTrack, outputSettings: videoReaderSettings)
        let videoReader = try! AVAssetReader(asset: videoAssetUrl)
        videoReader.add(videoReaderOutput)
        
        var settings = [String : AnyObject]()
        settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM) as AnyObject
        let audioReaderOutput = AVAssetReaderTrackOutput(track: audioAssetTrack, outputSettings: settings)
        let audioReader = try! AVAssetReader(asset: videoAssetUrl)
        audioReader.add(audioReaderOutput)
        
        videoWriter.startWriting()
        videoReader.startReading()
        videoWriter.startSession(atSourceTime: CMTime.zero)
        
        let processingVideoQueue = DispatchQueue(__label: "processingVideoCompressionQueue", attr: nil)
        
        videoWriterInput.requestMediaDataWhenReady(on: processingVideoQueue) {
            while (videoWriterInput.isReadyForMoreMediaData) {
                
                let sampleVideoBuffer = videoReaderOutput.copyNextSampleBuffer()
                if (videoReader.status == .reading && sampleVideoBuffer != nil) {
                    videoWriterInput.append(sampleVideoBuffer!)
                } else {
                    videoWriterInput.markAsFinished()
                    
                    if (videoReader.status == .completed) {
                        
                        audioReader.startReading()
                        videoWriter.startSession(atSourceTime: CMTime.zero)
                        
                        let processingAudioQueue = DispatchQueue(__label: "processingAudioCompressionQueue", attr: nil)
                        
                        audioWriterInput.requestMediaDataWhenReady(on: processingAudioQueue, using: {
                            while (audioWriterInput.isReadyForMoreMediaData) {
                                let sampleAudioBuffer = audioReaderOutput.copyNextSampleBuffer()
                                if (audioReader.status == .reading && sampleAudioBuffer != nil) {
                                    audioWriterInput.append(sampleAudioBuffer!)
                                } else {
                                    audioWriterInput.markAsFinished()
                                    
                                    if (audioReader.status == .completed) {
                                        videoWriter.finishWriting(completionHandler: {
                                            completion(true)
                                        })
                                    }
                                }
                            }
                        })
                    }
                }
            }
        }
    }
    
    func videoSettings(size : CGSize) -> [String : AnyObject] {
        
        var compressionSettings = [String : AnyObject]()
        compressionSettings[AVVideoAverageBitRateKey] = 425000 as AnyObject
        
        var settings = [String : AnyObject]()
        settings[AVVideoCompressionPropertiesKey] = compressionSettings as AnyObject
        settings[AVVideoCodecKey] = AVVideoCodecType.h264 as AnyObject?
        settings[AVVideoHeightKey] = size.height as AnyObject?
        settings[AVVideoWidthKey] = size.width as AnyObject?
        
        return settings
    }
    
//    func audioSettings() -> [String : AnyObject] {
//        // set up the channel layout
//        var channelLayout = AudioChannelLayout()
//        memset(&channelLayout, 0, size(forChildContentContainer: AudioChannelLayout, withParentContainerSize: .zero))
//        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
//
//        // set up a dictionary with our outputsettings
//        var settings = [String : AnyObject]()
//        settings[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC) as AnyObject
//        settings[AVSampleRateKey] = 44100 as AnyObject
//        settings[AVNumberOfChannelsKey] = 1 as AnyObject
//        settings[AVEncoderBitRateKey] = 96000 as AnyObject
//        settings[AVChannelLayoutKey] = NSData(bytes:&channelLayout, length:size(AudioChannelLayout))
//
//        return settings
//    }
}

extension FileManager {
    struct FolderNames {
        static let downloads = "DownloadedFiles"
        static let uploads = "UploadFiles"
    }
    
    func getPath() -> URL? {
        if let dirPath = folderUrl(FolderNames.uploads) {
            let filePath = dirPath.appendingPathComponent(UUID().uuidString + ".mov")
            return filePath
        }
        return nil
    }
    
    func fileSizeInBytes(path: URL) -> Int {
        let filePath = path.path
        
        do {
            let attribute = try attributesOfItem(atPath: filePath)
            if let size = attribute[FileAttributeKey.size] as? NSNumber {
                return size.intValue
            }
        } catch {
            print("Failed to determine file size: \(error)")
        }
        
        return 0
    }
    
    func folderUrl(_ name: String, inAppGroupsContainer: Bool = false) -> URL? {
        let url: URL?
        if inAppGroupsContainer {
            url = containerURL(forSecurityApplicationGroupIdentifier: "group.com.codebridge.voneapp")
        } else {
            url = urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        if let folderUrl = url?.appendingPathComponent(name, isDirectory: true) {
            if !fileExists(atPath: folderUrl.path) {
                do {
                    try createDirectory(atPath: folderUrl.path, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    return nil
                }
            }
            return folderUrl
        }
        return nil
    }
    
    func downloadedMediaPath(fileName: String) -> URL? {
        if let dirPath = folderUrl(FolderNames.downloads) {
            let pathName = dirPath.appendingPathComponent(fileName)
            return pathName
        }
        return nil
    }
    
    func audioRecordingPath() -> URL? {
        if let dirPath = folderUrl(FolderNames.uploads) {
            let pathName = dirPath.appendingPathComponent("\(UUID().uuidString).aac")
            return pathName
        }
        return nil
    }
    
    func completePathForLastPathComponent(_ component: String) -> URL? {
        if let dirPath = folderUrl(FolderNames.uploads) {
            return dirPath.appendingPathComponent(component)
        }
        return nil
    }
    
    func saveImage(_ image: UIImage, fileName name: String, thumbnailMaxPixelSize: Int) -> URL? {
        var imageToSave = image
        if let data = imageToSave.pngData() {
            let options = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize] as CFDictionary
            
            data.withUnsafeBytes { ptr in
                guard let bytes = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                if let cfData = CFDataCreate(kCFAllocatorDefault, bytes, data.count), let source = CGImageSourceCreateWithData(cfData, nil), let imgRef = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                    imageToSave = UIImage(cgImage: imgRef)
                }
            }
        }
        
        if let dirPath = folderUrl(FolderNames.uploads) {
            let filePath = dirPath.appendingPathComponent(name)
            if let data = imageToSave.jpegData(compressionQuality: 1) {
                do {
                    try data.write(to: filePath)
                    return filePath
                } catch {
                    print("Failed to save image: \(error)")
                    return nil
                }
            }
        }
        return nil
    }
    
    func removeFileWithPath(_ path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            print("Failed to remove file at path: \(path) \n error: \(error)")
        }
    }
}
