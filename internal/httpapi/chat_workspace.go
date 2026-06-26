package httpapi

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

const chatWorkspaceDisplayName = "Chats"

func (r *Router) chatWorkspaceHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}

	workspace, err := r.chatWorkspaceDescriptor()
	if err != nil {
		writeError(w, http.StatusForbidden, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, workspaceResolveResponse{Workspace: workspace})
}

func (r *Router) chatWorkspaceDescriptor() (workspaceDescriptor, error) {
	realPath, err := ensureChatWorkspaceRealPath()
	if err != nil {
		return workspaceDescriptor{}, err
	}
	id := workspaceIDForRealPath(realPath)
	return workspaceDescriptor{
		ID:              id,
		Name:            chatWorkspaceDisplayName,
		Path:            realPath,
		RootProjectID:   id,
		RootProjectName: chatWorkspaceDisplayName,
		RootProjectPath: realPath,
		Trusted:         true,
		CanStartSession: true,
	}, nil
}

func (r *Router) realPathIsChatWorkspace(realPath string) bool {
	chatPath, err := existingChatWorkspaceRealPath()
	if err != nil {
		return false
	}
	return realPathWithin(chatPath, realPath)
}

func ensureChatWorkspaceRealPath() (string, error) {
	path, err := chatWorkspacePath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return "", fmt.Errorf("无法创建 Chats 工作区：%w", err)
	}
	return existingChatWorkspaceRealPath()
}

func existingChatWorkspaceRealPath() (string, error) {
	path, err := chatWorkspacePath()
	if err != nil {
		return "", err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	stat, err := os.Stat(realPath)
	if err != nil {
		return "", err
	}
	if !stat.IsDir() {
		return "", fmt.Errorf("Chats 工作区路径不是目录")
	}
	return realPath, nil
}

func chatWorkspacePath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("无法定位用户 Home：%w", err)
	}
	if home == "" {
		return "", fmt.Errorf("无法定位用户 Home")
	}
	return filepath.Join(home, ".codex", "threads"), nil
}
