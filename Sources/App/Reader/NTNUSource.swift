//
//  NTNUSource.swift
//  App
//
//  Created by Mats Mollestad on 15/12/2018.
//

import Vapor
import Foundation


class NTNUSource {
    
    static var shared: NTNUSource = NTNUSource()
    
    /// The base url of the site
    /// NB: Because of the setup on the site, the last "/" needs to be omited
    private let baseUrl = "https://forelesning.gjovik.ntnu.no"
    
    /// The site to find the content
    private let startPath = "/publish/index.php"
    
    private var isSchedualed: Bool = false
    
    
    func fetchUpdates(with req: Request, startPage: Int = 0) {
        print("Fetching at: \(Date().description)")
        do {
            try loadRecords(with: req, baseUrl: baseUrl, path: startPath + "?page=\(startPage)")
        } catch {
            print("Error: ", error.localizedDescription)
        }
        
        guard !isSchedualed else { return }
        isSchedualed = true
        
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()

        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let min = calendar.component(.minute, from: now)

        var timeInterval: TimeInterval = 0

        timeInterval += (15 - Double(min))

        if hour < 18 && hour > 8 {
            timeInterval += 60 * 60
        } else {
            timeInterval += (9 + 24 - Double(hour)) * 60 * 60
        }

        if weekday == 7 {
            timeInterval += 2 * 24 * 60 * 60
        } else if weekday == 1 {
            timeInterval += 24 * 60 * 60
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeInterval) { [weak self] in
            self?.isSchedualed = false
            self?.fetchUpdates(with: req)
        }
    }
    
    
    private func loadRecords(with req: Request, baseUrl: String, path: String) throws {
        
        let recordsUrl = baseUrl + path
        _ = try req.client().get(recordsUrl).map({ [unowned self] (httpResponse) in
            guard let data = httpResponse.http.body.data,
                let document = try? XMLDocument(data: data, options: .documentTidyHTML),
                let recordingNodes = try? document.nodes(forXPath: "//tr[@class='lecture']") else {
                    throw Abort(.internalServerError)
            }
            
            var saves = [EventLoopFuture<Recording>]()
            
            for node in recordingNodes {
                if let recording = try? Recording.create(from: node, baseUrl: baseUrl + "/") {
                    
                    // Will throw if adding a recording if it allreay exists (because of unique constraint)
                    // May also do for some other instinces
                    _ = Recording.query(on: req).filter(\Recording.audioUrl, .equal, recording.audioUrl).first().map({ (existing) in
                        if existing == nil {
                            saves.append(recording.save(on: req))
                        }
                    })
                }
            }
            
            _ = saves.flatten(on: req)
            
            if let nextPageNode = try? document.nodes(forXPath: "//div[@class='paginator']//a[. = 'Neste']/@href"),
                let nextPagePath = nextPageNode.first?.stringValue {
                try self.loadRecords(with: req, baseUrl: baseUrl, path: nextPagePath)
            }
        })
    }
    
    static func allRecordings(from data: Data) throws -> (nextPath: String?, recoridngs: [Recording]) {
        
        let document = try XMLDocument(data: data, options: .documentTidyHTML)
        let recordingNodes = try document.nodes(forXPath: "//tr[@class='lecture']")
        
        var recordings = [Recording]()
        
        for node in recordingNodes {
            if let recording = try? Recording.create(from: node, baseUrl: "/") {
                recordings.append(recording)
            }
        }
        
        if let nextPageNode = try? document.nodes(forXPath: "//div[@class='paginator']//a[. = 'Neste']/@href"),
            let nextPagePath = nextPageNode.first?.stringValue {
            return (nextPagePath, recordings)
        } else {
            return (nil, recordings)
        }
    }
}
