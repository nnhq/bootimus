package wol

import (
	"encoding/hex"
	"fmt"
	"net"
	"strings"
)

// SendMagicPacket sends a Wake-on-LAN magic packet to the given MAC address.
// broadcastAddr should be a LAN broadcast address like "192.168.1.255" or "255.255.255.255".
func SendMagicPacket(macAddr, broadcastAddr string) error {
	mac, err := parseMACAddress(macAddr)
	if err != nil {
		return fmt.Errorf("invalid MAC address: %w", err)
	}

	if broadcastAddr == "" {
		broadcastAddr = "255.255.255.255"
	}

	// Magic packet: 6 bytes of 0xFF followed by MAC repeated 16 times (102 bytes total)
	var packet [102]byte
	for i := 0; i < 6; i++ {
		packet[i] = 0xFF
	}
	for i := 0; i < 16; i++ {
		copy(packet[6+i*6:], mac)
	}

	addr, err := net.ResolveUDPAddr("udp4", broadcastAddr+":9")
	if err != nil {
		return fmt.Errorf("failed to resolve broadcast address: %w", err)
	}

	conn, err := net.DialUDP("udp4", nil, addr)
	if err != nil {
		return fmt.Errorf("failed to open UDP connection: %w", err)
	}
	defer conn.Close()

	_, err = conn.Write(packet[:])
	if err != nil {
		return fmt.Errorf("failed to send magic packet: %w", err)
	}

	return nil
}

func parseMACAddress(mac string) ([]byte, error) {
	mac = strings.ReplaceAll(mac, ":", "")
	mac = strings.ReplaceAll(mac, "-", "")
	mac = strings.ToLower(mac)

	if len(mac) != 12 {
		return nil, fmt.Errorf("MAC address must be 12 hex characters, got %d", len(mac))
	}

	b, err := hex.DecodeString(mac)
	if err != nil {
		return nil, fmt.Errorf("invalid hex in MAC address: %w", err)
	}

	return b, nil
}
