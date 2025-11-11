<?php
// Debugging script for monitoring issues
// Location: /var/www/wireguard/monitoring-debug.php

echo "<h2>WireGuard Monitoring Debug</h2>";
echo "<pre>";

// Test 1: Check sudo access
echo "=== Test 1: Sudo Access ===\n";
$sudo_test = shell_exec("sudo -n whoami 2>&1");
echo "Result: " . ($sudo_test ?: "FAILED") . "\n\n";

// Test 2: Check wg command
echo "=== Test 2: WireGuard Status ===\n";
$wg_status = shell_exec("sudo wg show wg0 2>&1");
echo "Result:\n" . ($wg_status ?: "FAILED") . "\n\n";

// Test 3: Check wg dump
echo "=== Test 3: WireGuard Dump (for active peers) ===\n";
$wg_dump = shell_exec("sudo wg show wg0 dump 2>&1");
echo "Result:\n" . ($wg_dump ?: "FAILED") . "\n\n";

// Test 4: Parse active peers
echo "=== Test 4: Parse Active Peers ===\n";
if ($wg_dump) {
    $lines = explode("\n", $wg_dump);
    echo "Total lines: " . count($lines) . "\n";
    
    for ($i = 1; $i < count($lines); $i++) {
        $line = trim($lines[$i]);
        if (empty($line)) continue;
        
        $parts = preg_split('/\s+/', $line);
        if (count($parts) >= 5) {
            $endpoint = $parts[2];
            $allowed_ips = $parts[3];
            $last_handshake = intval($parts[4]);
            
            $current_time = time();
            $handshake_age = $current_time - $last_handshake;
            
            echo "Peer #$i:\n";
            echo "  Endpoint: $endpoint\n";
            echo "  Allowed IPs: $allowed_ips\n";
            echo "  Last Handshake: $last_handshake (" . date('Y-m-d H:i:s', $last_handshake) . ")\n";
            echo "  Age: $handshake_age seconds\n";
            echo "  Status: " . ($handshake_age < 180 ? "ACTIVE ✓" : "INACTIVE ✗") . "\n\n";
        }
    }
}

// Test 5: Check geolocation API
echo "=== Test 5: Geolocation API Test ===\n";
$test_ip = "8.8.8.8";
$api_url = "http://ip-api.com/json/{$test_ip}?fields=status,message,country,countryCode,city";
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, $api_url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$response = curl_exec($ch);
$http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

echo "API URL: $api_url\n";
echo "HTTP Code: $http_code\n";
echo "Response: " . ($response ?: "FAILED") . "\n\n";

// Test 6: Check clients.db
echo "=== Test 6: Clients Database ===\n";
$client_db = '/etc/wireguard/clients.db';
if (file_exists($client_db)) {
    $lines = file($client_db, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    echo "Total clients: " . count($lines) . "\n";
    foreach ($lines as $line) {
        if (strpos($line, '#') === 0) continue;
        $parts = explode('|', $line);
        if (count($parts) >= 4) {
            echo "  - {$parts[0]} -> {$parts[3]}\n";
        }
    }
} else {
    echo "Clients database not found!\n";
}

echo "\n=== End Debug ===\n";
echo "</pre>";

echo "<p><a href='index.php'>← بازگشت به پنل</a></p>";
?>
