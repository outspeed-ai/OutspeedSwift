import Foundation

public class Utils {
    static func GetEphemeralKey(apiKey: String, sessionConfig: SessionConfig, baseUrl: String) async throws -> [String: Any] {

        let urlString = "https://\(baseUrl)/v1/realtime/sessions"
        print("👉 using \(urlString) to create session...")
        
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Convert sessionConfig to JSON
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(sessionConfig)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "Invalid response", code: -1)
            }
            
            if !(200...299).contains(httpResponse.statusCode) {
                if let errorMessage = String(data: data, encoding: .utf8) {
                    print("Token generation error:", errorMessage)
                    throw NSError(domain: "API Error", 
                                code: httpResponse.statusCode, 
                                userInfo: [
                                    "type": "error",
                                    "message": errorMessage
                                ])
                } else {
                    throw NSError(domain: "API Error", code: httpResponse.statusCode)
                }
            }
            
            // Parse response
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Invalid JSON response", code: -1)
            }
            
            return json
            
        } catch {
            print("Token generation error:", error)
            throw NSError(domain: "API Error", 
                         code: 500, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to generate token"])
        }
    }
}
