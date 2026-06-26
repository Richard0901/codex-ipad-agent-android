package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// filePreviewMaxBytes 限制单个预览文件大小。QuickLook 适合查看产物，不适合把大文件当下载通道。
var filePreviewMaxBytes int64 = 20 << 20

type fileReadRequest struct {
	Path string `json:"path"`
}

type fileReadResponse struct {
	Path          string `json:"path"`
	Name          string `json:"name"`
	ContentType   string `json:"content_type"`
	Size          int64  `json:"size"`
	ContentBase64 string `json:"content_base64"`
}

func (r *Router) fileReadHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload fileReadRequest
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体不是合法 JSON")
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	scope, ok := r.gatewayScopeForPath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	realPath := scope.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是文件")
		return
	}
	if !stat.Mode().IsRegular() {
		writeError(w, http.StatusBadRequest, "仅支持普通文件预览")
		return
	}
	if stat.Size() > filePreviewMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "文件过大，暂不支持预览")
		return
	}

	data, err := os.ReadFile(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	contentType := detectFileContentType(realPath, data)
	writeJSON(w, http.StatusOK, fileReadResponse{
		Path:          realPath,
		Name:          filepath.Base(realPath),
		ContentType:   contentType,
		Size:          int64(len(data)),
		ContentBase64: base64.StdEncoding.EncodeToString(data),
	})
}

func detectFileContentType(path string, data []byte) string {
	if value := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); value != "" {
		return value
	}
	if len(data) == 0 {
		return "application/octet-stream"
	}
	sample := data
	if len(sample) > 512 {
		sample = sample[:512]
	}
	return http.DetectContentType(sample)
}
