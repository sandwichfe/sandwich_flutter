package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
)

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if payload == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("写入 JSON 失败: %v", err)
	}
}

// writeError 用 JSON 返回错误信息，客户端可以取出 message 直接展示给用户。
// 早期版本返回纯文本，前端已同步改为兼容两种格式。
func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"message": message,
		"status":  status,
	})
}

func writeNoContent(w http.ResponseWriter) {
	w.WriteHeader(http.StatusNoContent)
}

func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if strings.EqualFold(value, target) {
			return true
		}
	}
	return false
}

func atoi(value string) int {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return 0
	}
	return parsed
}

func parseIntList(values []string) []int {
	result := make([]int, 0, len(values))
	for _, value := range values {
		if parsed, err := strconv.Atoi(value); err == nil {
			result = append(result, parsed)
		}
	}
	return result
}

func queryBool(r *http.Request, key string) bool {
	return strings.EqualFold(r.URL.Query().Get(key), "true")
}
