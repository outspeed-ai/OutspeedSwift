import Foundation

@MainActor
public class Utils {
    static func GetEphemeralKey(apiKey: String, sessionConfig: SessionConfig, baseUrl: String) async throws -> [String: Any] {
        let urlString = "https://\(baseUrl)/v1/realtime/sessions"
        print("[Utils] 🚀 Starting ephemeral key generation...")
        print("[Utils] 📡 Target URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("[Utils] ❌ Invalid URL construction: \(urlString)")
            throw NSError(domain: "Invalid URL", code: -1)
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        print("[Utils] 📤 Request headers set:")
        print("[Utils]   - Authorization: Bearer \(String(apiKey.prefix(4)))...")
        print("[Utils]   - Content-Type: application/json")
        
        // Convert sessionConfig to JSON
        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(sessionConfig)
            print("[Utils] ✅ SessionConfig encoded successfully")
            
            // Log the encoded session config for debugging
            if let jsonString = String(data: request.httpBody!, encoding: .utf8) {
                print("[Utils] 📝 Request body:")
                print(jsonString)
            }
        } catch {
            print("[Utils] ❌ Failed to encode SessionConfig: \(error)")
            throw error
        }
        
        do {
            print("[Utils] 🚀 Sending request to server...")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Utils] ❌ Invalid response type received")
                throw NSError(domain: "Invalid response", code: -1)
            }
            
            print("[Utils] 📥 Received response with status code: \(httpResponse.statusCode)")
            
            if !(200...299).contains(httpResponse.statusCode) {
                if let errorMessage = String(data: data, encoding: .utf8) {
                    print("[Utils] ❌ Server error response:")
                    print(errorMessage)
                    throw NSError(domain: "API Error", 
                                code: httpResponse.statusCode, 
                                userInfo: [
                                    "type": "error",
                                    "message": errorMessage
                                ])
                } else {
                    print("[Utils] ❌ Server error with no message body")
                    throw NSError(domain: "API Error", code: httpResponse.statusCode)
                }
            }
            
            // Parse response
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[Utils] ❌ Failed to parse JSON response")
                throw NSError(domain: "Invalid JSON response", code: -1)
            }
            
            print("[Utils] ✅ Successfully parsed JSON response")
            print("[Utils] 📦 Response keys: \(json.keys.joined(separator: ", "))")
            
            return json
            
        } catch {
            print("[Utils] ❌ Request failed with error: \(error)")
            throw NSError(domain: "API Error", 
                         code: 500, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to generate token"])
        }
    }
}
