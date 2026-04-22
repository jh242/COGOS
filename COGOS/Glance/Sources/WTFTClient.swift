import Foundation

/// Minimal client for https://api.wheresthefuckingtrain.com — returns
/// NYC subway stations near a coordinate, each with upcoming arrivals.
/// Free, no API key.
enum WTFTClient {
    struct Arrival: Decodable {
        let route: String
        let time: Date
    }

    struct Station: Decodable {
        let id: String
        let name: String
        let location: [Double]  // [lat, lon]
        let N: [Arrival]
        let S: [Arrival]

        var latitude: Double? { location.count >= 2 ? location[0] : nil }
        var longitude: Double? { location.count >= 2 ? location[1] : nil }
    }

    private struct Response: Decodable {
        let data: [Station]
    }

    static func fetchByLocation(lat: Double, lon: Double) async throws -> [Station] {
        guard let url = URL(string: "https://api.wheresthefuckingtrain.com/by-location?lat=\(lat)&lon=\(lon)") else {
            return []
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        let (data, _) = try await URLSession.shared.data(for: req)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).data
    }
}
