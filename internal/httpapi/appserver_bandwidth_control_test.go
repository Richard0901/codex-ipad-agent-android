package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAppServerGatewayRedactsImageGenerationNotificationsAndDeduplicates(t *testing.T) {
	t.Setenv("AGENTD_MEDIA_REDACT_NOTIFICATIONS", "")
	router := &Router{historyMedia: newAppServerHistoryMediaStore()}
	policy := &appServerGatewayPolicy{router: router, runtimeID: "codex"}
	imagePayload := base64.StdEncoding.EncodeToString(testHistoryNoisyPNG(t, 256, 256))
	payload := []byte(`{"method":"item/completed","params":{"item":{"type":"imageGeneration","id":"ig_1","status":"completed","result":"` + imagePayload + `"}}}`)

	first, forward, policyErr := policy.observeUpstreamFrame(1, payload)
	if policyErr != nil || !forward {
		t.Fatalf("通知帧不应被阻断：forward=%v err=%v", forward, policyErr)
	}
	second, forward, policyErr := policy.observeUpstreamFrame(1, payload)
	if policyErr != nil || !forward {
		t.Fatalf("重复通知帧不应被阻断：forward=%v err=%v", forward, policyErr)
	}
	if bytes.Contains(first, []byte(imagePayload)) || bytes.Contains(second, []byte(imagePayload)) {
		t.Fatalf("通知帧不应继续携带裸 base64")
	}

	firstURL := historyMediaURLFromNotification(t, first)
	secondURL := historyMediaURLFromNotification(t, second)
	if firstURL == "" || firstURL != secondURL {
		t.Fatalf("同一图片应复用稳定 media URL，first=%q second=%q", firstURL, secondURL)
	}
}

func TestAppServerGatewayNotificationRedactionCanBeDisabled(t *testing.T) {
	t.Setenv("AGENTD_MEDIA_REDACT_NOTIFICATIONS", "off")
	router := &Router{historyMedia: newAppServerHistoryMediaStore()}
	policy := &appServerGatewayPolicy{router: router, runtimeID: "codex"}
	imagePayload := base64.StdEncoding.EncodeToString(testHistoryNoisyPNG(t, 256, 256))
	payload := []byte(`{"method":"item/completed","params":{"item":{"type":"imageGeneration","result":"` + imagePayload + `"}}}`)

	got, forward, policyErr := policy.observeUpstreamFrame(1, payload)
	if policyErr != nil || !forward {
		t.Fatalf("关闭改写时通知帧仍应透传：forward=%v err=%v", forward, policyErr)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("关闭改写后 payload 不应变化")
	}
}

func TestAppServerHistoryMediaStoreDeduplicatesAndPrunesHashIndex(t *testing.T) {
	oldMaxEntries := appServerHistoryMediaMaxEntries
	appServerHistoryMediaMaxEntries = 1
	t.Cleanup(func() { appServerHistoryMediaMaxEntries = oldMaxEntries })

	store := newAppServerHistoryMediaStore()
	first, ok := store.put("image/png", []byte("same-image"))
	if !ok {
		t.Fatal("首次 put 应成功")
	}
	again, ok := store.put("image/png", []byte("same-image"))
	if !ok || again != first {
		t.Fatalf("相同内容应复用 id，first=%q again=%q ok=%v", first, again, ok)
	}
	second, ok := store.put("image/png", []byte("different-image"))
	if !ok || second == first {
		t.Fatalf("不同内容应生成新 id，second=%q ok=%v", second, ok)
	}
	third, ok := store.put("image/png", []byte("same-image"))
	if !ok {
		t.Fatal("被淘汰后再次 put 应成功")
	}
	if third == first {
		t.Fatalf("淘汰后 hash 索引不能悬挂复用旧 id：first=%q third=%q", first, third)
	}
}

func TestAppServerGatewayGlobalHistoryBudgetLimitsAcrossThreads(t *testing.T) {
	oldMax := appServerGatewayHistoryGlobalMaxResponseBytes
	oldWindow := appServerGatewayHistoryGlobalWindow
	appServerGatewayHistoryGlobalMaxResponseBytes = 1000
	appServerGatewayHistoryGlobalWindow = 15 * time.Second
	t.Cleanup(func() {
		appServerGatewayHistoryGlobalMaxResponseBytes = oldMax
		appServerGatewayHistoryGlobalWindow = oldWindow
	})

	router := &Router{}
	firstPolicy := &appServerGatewayPolicy{router: router, pendingHistory: map[string]appServerGatewayPendingHistoryRequest{}, historyBudgets: map[string]appServerGatewayHistoryBudget{}}
	secondPolicy := &appServerGatewayPolicy{router: router, pendingHistory: map[string]appServerGatewayPendingHistoryRequest{}, historyBudgets: map[string]appServerGatewayHistoryBudget{}}
	firstPolicy.recordHistoryResponseBudget(appServerGatewayPendingHistoryRequest{method: "thread/turns/list", threadID: "thread-a", itemsView: "full"}, 700)
	secondPolicy.recordHistoryResponseBudget(appServerGatewayPendingHistoryRequest{method: "thread/turns/list", threadID: "thread-b", itemsView: "full"}, 400)

	id := json.RawMessage(`3`)
	err := firstPolicy.reserveHistoryRequest(&id, "thread/turns/list", map[string]any{
		"threadId":  "thread-c",
		"itemsView": "summary",
	}, 128)
	if err == nil || !err.historyBudgetRejected || err.data["reason"] != "history_budget_limited" {
		t.Fatalf("跨 thread 超过全局预算后应限流，err=%+v", err)
	}

	resumeID := json.RawMessage(`4`)
	if err := firstPolicy.reserveHistoryRequest(&resumeID, "thread/resume", map[string]any{"threadId": "thread-c"}, 128); err != nil {
		t.Fatalf("thread/resume redact-only 不应受全局预算阻断：%+v", err)
	}
}

func TestRelayMonitorRecordsForwardedAndRedactedBytes(t *testing.T) {
	monitor := newRelayMonitor()
	conn := monitor.startGatewayConnection("127.0.0.1", "example.test", "ws://upstream", 0)
	conn.recordForward("upstream_to_client", 1000, 120, 2*time.Millisecond, 3*time.Millisecond, []byte(`{"method":"item/completed"}`))

	snapshot := monitor.snapshot()
	dir := snapshot.AppServerGateway.UpstreamToClient
	if dir.Bytes != 1000 || dir.ForwardedBytes != 120 {
		t.Fatalf("diagnostics 应同时保留原始和实际转发字节：%+v", dir)
	}
	if dir.RedactedFrames != 1 || dir.RedactedBytesSaved != 880 {
		t.Fatalf("diagnostics 应记录 redaction 节省量：%+v", dir)
	}
}

func TestAppServerHistoryMediaHandlerDownsamplesAndCachesDerivedImage(t *testing.T) {
	router := &Router{historyMedia: newAppServerHistoryMediaStore()}
	original := testHistoryNoisyPNG(t, 2000, 1200)
	id, ok := router.historyMedia.put("image/png", original)
	if !ok {
		t.Fatal("history media put 应成功")
	}

	rec := httptest.NewRecorder()
	router.appServerHistoryMediaHandler(rec, httptest.NewRequest(http.MethodGet, "/api/app-server/history-media/"+id, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("默认取图应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var body fileReadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应应是 fileReadResponse：%v", err)
	}
	if body.ContentType != "image/jpeg" {
		t.Fatalf("不透明大 PNG 默认应降采样为 JPEG，got=%s", body.ContentType)
	}
	if body.OriginalByteCount != int64(len(original)) || body.Size >= int64(len(original)) {
		t.Fatalf("响应应标注原始大小并明显减重：size=%d original=%d field=%d", body.Size, len(original), body.OriginalByteCount)
	}
	decoded := decodeFileReadImage(t, body)
	if max(decoded.Bounds().Dx(), decoded.Bounds().Dy()) != appServerHistoryMediaDerivedMaxDimension {
		t.Fatalf("降采样长边应为 %d，bounds=%v", appServerHistoryMediaDerivedMaxDimension, decoded.Bounds())
	}
	totalAfterFirst := router.historyMedia.totalBytesForTest()

	rec = httptest.NewRecorder()
	router.appServerHistoryMediaHandler(rec, httptest.NewRequest(http.MethodGet, "/api/app-server/history-media/"+id, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("第二次取图应命中缓存，got=%d", rec.Code)
	}
	if totalAfterSecond := router.historyMedia.totalBytesForTest(); totalAfterSecond != totalAfterFirst {
		t.Fatalf("二次请求不应重复计入 derived 缓存：first=%d second=%d", totalAfterFirst, totalAfterSecond)
	}
}

func TestAppServerHistoryMediaHandlerPreservesOriginalAndTransparentPNG(t *testing.T) {
	router := &Router{historyMedia: newAppServerHistoryMediaStore()}
	transparent := testHistoryPNG(t, 256, 256, true)
	id, ok := router.historyMedia.put("image/png", transparent)
	if !ok {
		t.Fatal("history media put 应成功")
	}

	rec := httptest.NewRecorder()
	router.appServerHistoryMediaHandler(rec, httptest.NewRequest(http.MethodGet, "/api/app-server/history-media/"+id, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("透明 PNG 默认取图应成功，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var body fileReadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应应是 fileReadResponse：%v", err)
	}
	if body.ContentType != "image/png" {
		t.Fatalf("透明 PNG 必须保留 PNG，got=%s", body.ContentType)
	}
	gotBytes, err := base64.StdEncoding.DecodeString(body.ContentBase64)
	if err != nil {
		t.Fatalf("content_base64 应可解码：%v", err)
	}
	if !bytes.Equal(gotBytes, transparent) {
		t.Fatalf("小透明 PNG 不需要降采样时应原样返回")
	}

	rec = httptest.NewRecorder()
	router.appServerHistoryMediaHandler(rec, httptest.NewRequest(http.MethodGet, "/api/app-server/history-media/"+id+"?original=1", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("original=1 应成功，got=%d", rec.Code)
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应应是 fileReadResponse：%v", err)
	}
	gotBytes, err = base64.StdEncoding.DecodeString(body.ContentBase64)
	if err != nil || !bytes.Equal(gotBytes, transparent) {
		t.Fatalf("original=1 必须逐字节返回原图，err=%v", err)
	}
}

func TestAppServerHistoryMediaHandlerReturnsInvalidImageAsOriginal(t *testing.T) {
	router := &Router{historyMedia: newAppServerHistoryMediaStore()}
	invalid := []byte("not-a-real-image")
	id, ok := router.historyMedia.put("image/png", invalid)
	if !ok {
		t.Fatal("history media put 应成功")
	}

	rec := httptest.NewRecorder()
	router.appServerHistoryMediaHandler(rec, httptest.NewRequest(http.MethodGet, "/api/app-server/history-media/"+id, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("非法图片数据应原样返回而不是 500，got=%d body=%s", rec.Code, rec.Body.String())
	}
	var body fileReadResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应应是 fileReadResponse：%v", err)
	}
	if body.ContentType != "image/png" || body.ContentBase64 != base64.StdEncoding.EncodeToString(invalid) {
		t.Fatalf("非法图片应按原始内容返回：%+v", body)
	}
}

func historyMediaURLFromNotification(t *testing.T, payload []byte) string {
	t.Helper()
	var root struct {
		Params struct {
			Item struct {
				Result string `json:"result"`
			} `json:"item"`
		} `json:"params"`
	}
	if err := json.Unmarshal(payload, &root); err != nil {
		t.Fatalf("通知帧应是合法 JSON：%v raw=%s", err, payload)
	}
	if !strings.HasPrefix(root.Params.Item.Result, appServerHistoryMediaURLPrefix) {
		t.Fatalf("通知帧 result 应替换为 media URL：%s", payload)
	}
	return root.Params.Item.Result
}

func testHistoryPNG(t *testing.T, width, height int, transparent bool) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			alpha := uint8(255)
			if transparent && x < width/3 && y < height/3 {
				alpha = 0
			}
			img.SetNRGBA(x, y, color.NRGBA{R: uint8(x % 251), G: uint8(y % 241), B: 180, A: alpha})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("生成 PNG 失败：%v", err)
	}
	return buf.Bytes()
}

func testHistoryNoisyPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	seed := uint32(1)
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			seed = seed*1664525 + 1013904223
			v := seed
			img.SetNRGBA(x, y, color.NRGBA{
				R: uint8(v),
				G: uint8(v >> 8),
				B: uint8(v >> 16),
				A: 255,
			})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("生成 noisy PNG 失败：%v", err)
	}
	return buf.Bytes()
}

func decodeFileReadImage(t *testing.T, body fileReadResponse) image.Image {
	t.Helper()
	data, err := base64.StdEncoding.DecodeString(body.ContentBase64)
	if err != nil {
		t.Fatalf("content_base64 应可解码：%v", err)
	}
	switch body.ContentType {
	case "image/jpeg":
		img, err := jpeg.Decode(bytes.NewReader(data))
		if err != nil {
			t.Fatalf("JPEG 应可解码：%v", err)
		}
		return img
	case "image/png":
		img, err := png.Decode(bytes.NewReader(data))
		if err != nil {
			t.Fatalf("PNG 应可解码：%v", err)
		}
		return img
	default:
		t.Fatalf("测试暂不支持 content_type=%s", body.ContentType)
		return nil
	}
}
