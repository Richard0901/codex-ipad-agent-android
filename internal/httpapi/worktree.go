package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

const worktreeCreateTimeout = 30 * time.Second
const worktreeStatusTimeout = 2 * time.Second

var errManagedWorktreeNotFound = errors.New("managed worktree not found")

type worktreeBranchListRequest struct {
	Path string `json:"path"`
}

type worktreeBranchListResponse struct {
	Path          string               `json:"path"`
	DefaultBase   string               `json:"default_base,omitempty"`
	CurrentBranch string               `json:"current_branch,omitempty"`
	Branches      []worktreeBranchItem `json:"branches"`
}

type worktreeBranchItem struct {
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	IsCurrent bool   `json:"is_current,omitempty"`
	IsDefault bool   `json:"is_default,omitempty"`
}

type worktreeCreateRequest struct {
	Path   string `json:"path"`
	Name   string `json:"name,omitempty"`
	Base   string `json:"base,omitempty"`
	Branch string `json:"branch,omitempty"`
}

type worktreeListResponse struct {
	Worktrees []worktreeListItem `json:"worktrees"`
}

type worktreeListItem struct {
	Workspace workspaceDescriptor `json:"workspace"`
	Worktree  worktreeDescriptor  `json:"worktree"`
}

type worktreeDeleteRequest struct {
	Path  string `json:"path"`
	Force bool   `json:"force,omitempty"`
}

type worktreeDeleteResponse struct {
	DeletedPath string               `json:"deleted_path"`
	Worktrees   []worktreeListItem   `json:"worktrees"`
	Workspace   *workspaceDescriptor `json:"workspace,omitempty"`
	Worktree    *worktreeDescriptor  `json:"worktree,omitempty"`
}

type worktreePruneResponse struct {
	PrunedPaths []string           `json:"pruned_paths"`
	Worktrees   []worktreeListItem `json:"worktrees"`
}

type worktreeCreateResponse struct {
	Workspace workspaceDescriptor `json:"workspace"`
	Worktree  worktreeDescriptor  `json:"worktree"`
}

type worktreeDescriptor struct {
	Path            string `json:"path"`
	RepositoryPath  string `json:"repository_path"`
	Base            string `json:"base"`
	Branch          string `json:"branch,omitempty"`
	Dirty           bool   `json:"dirty,omitempty"`
	Ahead           int    `json:"ahead,omitempty"`
	Behind          int    `json:"behind,omitempty"`
	Upstream        string `json:"upstream,omitempty"`
	RootProjectID   string `json:"root_project_id"`
	RootProjectName string `json:"root_project_name"`
	RootProjectPath string `json:"root_project_path"`
}

type managedWorktree struct {
	Path           string           `json:"path"`
	RepositoryPath string           `json:"repository_path"`
	Base           string           `json:"base"`
	Branch         string           `json:"branch,omitempty"`
	RootProject    projects.Project `json:"root_project"`
}

func (r *Router) worktreeListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, worktreeListResponse{
		Worktrees: r.managedWorktreeListItems(req.Context()),
	})
}

func (r *Router) worktreeBranchListHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeBranchListRequest
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
	stat, err := os.Stat(scope.realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if !stat.IsDir() {
		writeError(w, http.StatusBadRequest, "path 必须是目录")
		return
	}

	response, err := r.worktreeBranchList(req.Context(), scope.realPath)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) worktreeCreateHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeCreateRequest
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
	if scope.browse || strings.TrimSpace(scope.project.ID) == "" {
		writeError(w, http.StatusBadRequest, "Worktree 只能从已配置项目创建")
		return
	}

	workspace, worktree, err := r.createManagedWorktree(req.Context(), scope, strings.TrimSpace(payload.Name), strings.TrimSpace(payload.Base), strings.TrimSpace(payload.Branch))
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, worktreeCreateResponse{
		Workspace: workspace,
		Worktree:  worktree,
	})
}

func (r *Router) worktreeDeleteHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload worktreeDeleteRequest
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
	deleted, err := r.deleteManagedWorktree(req.Context(), path, payload.Force)
	if err != nil {
		if errors.Is(err, errManagedWorktreeNotFound) {
			writeError(w, http.StatusForbidden, "只能删除 agentd 创建并登记过的 Worktree")
			return
		}
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, worktreeDeleteResponse{
		DeletedPath: deleted.Path,
		Worktrees:   r.managedWorktreeListItems(req.Context()),
	})
}

func (r *Router) worktreePruneHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	pruned := r.pruneMissingManagedWorktrees()
	writeJSON(w, http.StatusOK, worktreePruneResponse{
		PrunedPaths: pruned,
		Worktrees:   r.managedWorktreeListItems(req.Context()),
	})
}

func (r *Router) createManagedWorktree(ctx context.Context, scope gatewayScope, name string, base string, branch string) (workspaceDescriptor, worktreeDescriptor, error) {
	ctx, cancel := context.WithTimeout(ctx, worktreeCreateTimeout)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("git 不可用：%w", err)
	}
	repoRoot, _, err := runGitReadOnly(ctx, scope.realPath, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		if isGitRepositoryMissingError(err) {
			return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("当前工作区不是 Git 仓库")
		}
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	repoRoot = strings.TrimSpace(repoRoot)
	if repoRoot == "" {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("无法识别 Git 仓库根目录")
	}
	projectRel, err := filepath.Rel(repoRoot, scope.realPath)
	if err != nil || projectRel == ".." || strings.HasPrefix(projectRel, ".."+string(os.PathSeparator)) {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("项目路径不在 Git 仓库内")
	}

	baseRef := "HEAD"
	if base != "" {
		normalized, err := normalizedWorktreeBase(base)
		if err != nil {
			return workspaceDescriptor{}, worktreeDescriptor{}, err
		}
		baseRef = normalized
	}
	commitish := baseRef
	if _, _, err := runGitReadOnly(ctx, repoRoot, 16*1024, "rev-parse", "--verify", baseRef+"^{commit}"); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("base 不是有效提交：%w", err)
	}

	root, err := r.worktreesRoot()
	if err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	projectRoot := filepath.Join(root, "checkouts", scope.project.ID)
	if err := os.MkdirAll(projectRoot, 0o755); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("创建 worktree 根目录失败：%w", err)
	}
	slug := sanitizedWorktreeName(firstNonEmpty(name, scope.project.Name))
	timestamp := time.Now().UTC().Format("20060102-150405")
	branchName, err := r.worktreeBranchName(ctx, repoRoot, branch, firstNonEmpty(name, scope.project.Name), timestamp)
	if err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	target := filepath.Join(projectRoot, fmt.Sprintf("%s-%s", slug, timestamp))
	for i := 2; pathExists(target); i++ {
		target = filepath.Join(projectRoot, fmt.Sprintf("%s-%s-%d", slug, timestamp, i))
	}

	if _, _, err := runGitCommand(ctx, repoRoot, 32*1024, "worktree", "add", "-b", branchName, target, commitish); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}
	workspacePath := target
	if projectRel != "." {
		workspacePath = filepath.Join(target, projectRel)
	}
	realWorkspacePath, err := filepath.EvalSymlinks(workspacePath)
	if err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, fmt.Errorf("读取 worktree 路径失败：%w", err)
	}
	worktree := managedWorktree{
		Path:           realWorkspacePath,
		RepositoryPath: repoRoot,
		Base:           baseRef,
		Branch:         branchName,
		RootProject:    scope.project,
	}
	if err := r.registerManagedWorktree(worktree); err != nil {
		return workspaceDescriptor{}, worktreeDescriptor{}, err
	}

	workspace := workspaceDescriptor{
		ID:              workspaceIDForRealPath(realWorkspacePath),
		Name:            filepath.Base(realWorkspacePath),
		Path:            realWorkspacePath,
		RootProjectID:   scope.project.ID,
		RootProjectName: scope.project.Name,
		RootProjectPath: scope.project.Path,
		Trusted:         true,
		CanStartSession: true,
	}
	return workspace, worktreeDescriptorForManagedWorktree(ctx, worktree), nil
}

func (r *Router) pruneMissingManagedWorktrees() []string {
	items := r.managedWorktreeMapFromRegistryRaw()
	r.managedWorktreesMu.Lock()
	for path, worktree := range r.managedWorktrees {
		items[path] = worktree
	}
	r.managedWorktreesMu.Unlock()

	pruned := make([]string, 0)
	for path, worktree := range items {
		if _, ok := r.projects.Get(worktree.RootProject.ID); !ok {
			r.unregisterManagedWorktree(path)
			pruned = append(pruned, path)
			continue
		}
		if _, err := os.Stat(worktree.Path); err != nil {
			if os.IsNotExist(err) {
				r.unregisterManagedWorktree(path)
				pruned = append(pruned, path)
			}
		}
	}
	sort.Strings(pruned)
	return pruned
}

func (r *Router) deleteManagedWorktree(ctx context.Context, rawPath string, force bool) (managedWorktree, error) {
	ctx, cancel := context.WithTimeout(ctx, worktreeCreateTimeout)
	defer cancel()

	worktree, ok := r.managedWorktreeByExactPath(rawPath)
	if !ok {
		return managedWorktree{}, errManagedWorktreeNotFound
	}

	if _, err := os.Stat(worktree.Path); err != nil {
		if os.IsNotExist(err) {
			r.unregisterManagedWorktree(worktree.Path)
			return worktree, nil
		}
		return managedWorktree{}, fmt.Errorf("读取 worktree 失败：%w", err)
	}
	if _, err := exec.LookPath("git"); err != nil {
		return managedWorktree{}, fmt.Errorf("git 不可用：%w", err)
	}
	checkoutRoot, _, err := runGitReadOnly(ctx, worktree.Path, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		return managedWorktree{}, err
	}
	checkoutRoot = strings.TrimSpace(checkoutRoot)
	if checkoutRoot == "" {
		return managedWorktree{}, fmt.Errorf("无法识别 Worktree checkout 根目录")
	}

	commandDir := worktree.RepositoryPath
	if _, err := os.Stat(commandDir); err != nil {
		return managedWorktree{}, fmt.Errorf("原始仓库不可访问，无法安全删除 worktree：%w", err)
	}
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, checkoutRoot)
	if _, _, err := runGitCommand(ctx, commandDir, 32*1024, args...); err != nil {
		return managedWorktree{}, err
	}
	r.unregisterManagedWorktree(worktree.Path)
	return worktree, nil
}

func (r *Router) registerManagedWorktree(worktree managedWorktree) error {
	if strings.TrimSpace(worktree.Path) == "" || strings.TrimSpace(worktree.RootProject.ID) == "" {
		return fmt.Errorf("worktree 元数据不完整")
	}
	r.managedWorktreesMu.Lock()
	r.managedWorktrees[worktree.Path] = worktree
	r.managedWorktreesMu.Unlock()

	root, err := r.worktreesRoot()
	if err != nil {
		return err
	}
	registryDir := filepath.Join(root, "registry")
	if err := os.MkdirAll(registryDir, 0o755); err != nil {
		return fmt.Errorf("创建 worktree registry 失败：%w", err)
	}
	data, err := json.MarshalIndent(worktree, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化 worktree registry 失败：%w", err)
	}
	file := filepath.Join(registryDir, workspaceIDForRealPath(worktree.Path)+".json")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		return fmt.Errorf("写入 worktree registry 失败：%w", err)
	}
	return nil
}

func (r *Router) unregisterManagedWorktree(path string) {
	r.managedWorktreesMu.Lock()
	delete(r.managedWorktrees, path)
	r.managedWorktreesMu.Unlock()

	root, err := r.worktreesRoot()
	if err != nil {
		return
	}
	_ = os.Remove(filepath.Join(root, "registry", workspaceIDForRealPath(path)+".json"))
}

func (r *Router) managedWorktreeForPath(realPath string) (managedWorktree, bool) {
	if worktree, ok := r.managedWorktreeForPathFromMemory(realPath); ok {
		return worktree, true
	}
	if worktree, ok := r.managedWorktreeForPathFromRegistry(realPath); ok {
		r.managedWorktreesMu.Lock()
		r.managedWorktrees[worktree.Path] = worktree
		r.managedWorktreesMu.Unlock()
		return worktree, true
	}
	return managedWorktree{}, false
}

func (r *Router) managedWorktreeForPathFromMemory(realPath string) (managedWorktree, bool) {
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()
	return managedWorktreeForPathInMap(r.managedWorktrees, realPath)
}

func (r *Router) managedWorktreeForPathFromRegistry(realPath string) (managedWorktree, bool) {
	items := r.managedWorktreeMapFromRegistry(true)
	return managedWorktreeForPathInMap(items, realPath)
}

func (r *Router) managedWorktreeByExactPath(rawPath string) (managedWorktree, bool) {
	path := strings.TrimSpace(rawPath)
	if path == "" {
		return managedWorktree{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return managedWorktree{}, false
	}
	candidates := []string{filepath.Clean(abs)}
	if realPath, err := filepath.EvalSymlinks(abs); err == nil {
		candidates = append(candidates, filepath.Clean(realPath))
	}
	items := r.allManagedWorktreeMap(false)
	for _, candidate := range candidates {
		if worktree, ok := items[candidate]; ok {
			return worktree, true
		}
	}
	return managedWorktree{}, false
}

func (r *Router) managedWorktreeListItems(ctx context.Context) []worktreeListItem {
	items := r.allManagedWorktreeMap(true)
	worktrees := make([]managedWorktree, 0, len(items))
	for _, worktree := range items {
		worktrees = append(worktrees, worktree)
	}
	sort.Slice(worktrees, func(i, j int) bool {
		if worktrees[i].RootProject.Name != worktrees[j].RootProject.Name {
			return worktrees[i].RootProject.Name < worktrees[j].RootProject.Name
		}
		return worktrees[i].Path < worktrees[j].Path
	})
	out := make([]worktreeListItem, 0, len(worktrees))
	for _, worktree := range worktrees {
		out = append(out, worktreeListItem{
			Workspace: workspaceDescriptorForManagedWorktree(worktree),
			Worktree:  worktreeDescriptorForManagedWorktree(ctx, worktree),
		})
	}
	return out
}

func (r *Router) allManagedWorktreeMap(existingOnly bool) map[string]managedWorktree {
	items := r.managedWorktreeMapFromRegistry(existingOnly)
	r.managedWorktreesMu.Lock()
	defer r.managedWorktreesMu.Unlock()
	for path, worktree := range r.managedWorktrees {
		if existingOnly {
			if _, err := os.Stat(worktree.Path); err != nil {
				continue
			}
		}
		project, ok := r.projects.Get(worktree.RootProject.ID)
		if !ok {
			continue
		}
		worktree.RootProject = project
		items[path] = worktree
	}
	return items
}

func (r *Router) managedWorktreeMapFromRegistry(existingOnly bool) map[string]managedWorktree {
	items := map[string]managedWorktree{}
	for path, worktree := range r.managedWorktreeMapFromRegistryRaw() {
		project, ok := r.projects.Get(worktree.RootProject.ID)
		if !ok {
			continue
		}
		worktree.RootProject = project
		if existingOnly {
			if _, err := os.Stat(worktree.Path); err != nil {
				continue
			}
		}
		items[path] = worktree
	}
	return items
}

func (r *Router) managedWorktreeMapFromRegistryRaw() map[string]managedWorktree {
	items := map[string]managedWorktree{}
	root, err := r.worktreesRoot()
	if err != nil {
		return items
	}
	entries, err := os.ReadDir(filepath.Join(root, "registry"))
	if err != nil {
		return items
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, "registry", entry.Name()))
		if err != nil {
			continue
		}
		var worktree managedWorktree
		if json.Unmarshal(data, &worktree) != nil {
			continue
		}
		if strings.TrimSpace(worktree.Path) == "" {
			continue
		}
		items[worktree.Path] = worktree
	}
	return items
}

func managedWorktreeForPathInMap(items map[string]managedWorktree, realPath string) (managedWorktree, bool) {
	var best managedWorktree
	bestDepth := -1
	for _, worktree := range items {
		if !realPathWithin(worktree.Path, realPath) {
			continue
		}
		depth := strings.Count(filepath.Clean(worktree.Path), string(os.PathSeparator))
		if depth > bestDepth {
			best = worktree
			bestDepth = depth
		}
	}
	return best, bestDepth >= 0
}

func workspaceDescriptorForManagedWorktree(worktree managedWorktree) workspaceDescriptor {
	return workspaceDescriptor{
		ID:              workspaceIDForRealPath(worktree.Path),
		Name:            filepath.Base(worktree.Path),
		Path:            worktree.Path,
		RootProjectID:   worktree.RootProject.ID,
		RootProjectName: worktree.RootProject.Name,
		RootProjectPath: worktree.RootProject.Path,
		Trusted:         true,
		CanStartSession: true,
	}
}

func worktreeDescriptorForManagedWorktree(ctx context.Context, worktree managedWorktree) worktreeDescriptor {
	descriptor := worktreeDescriptor{
		Path:            worktree.Path,
		RepositoryPath:  worktree.RepositoryPath,
		Base:            worktree.Base,
		Branch:          worktree.Branch,
		RootProjectID:   worktree.RootProject.ID,
		RootProjectName: worktree.RootProject.Name,
		RootProjectPath: worktree.RootProject.Path,
	}
	dirty, ahead, behind, upstream := managedWorktreeGitState(ctx, worktree.Path)
	descriptor.Dirty = dirty
	descriptor.Ahead = ahead
	descriptor.Behind = behind
	descriptor.Upstream = upstream
	return descriptor
}

func managedWorktreeGitState(ctx context.Context, path string) (bool, int, int, string) {
	ctx, cancel := context.WithTimeout(ctx, worktreeStatusTimeout)
	defer cancel()

	if _, err := exec.LookPath("git"); err != nil {
		return false, 0, 0, ""
	}
	status, _, err := runGitReadOnly(ctx, path, 32*1024, "status", "--porcelain=v1", "--untracked-files=normal", "--", ".")
	dirty := err == nil && strings.TrimSpace(status) != ""

	upstreamOutput, _, err := runGitReadOnly(ctx, path, 4*1024, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
	if err != nil {
		return dirty, 0, 0, ""
	}
	upstream := strings.TrimSpace(upstreamOutput)
	if upstream == "" {
		return dirty, 0, 0, ""
	}

	counts, _, err := runGitReadOnly(ctx, path, 4*1024, "rev-list", "--left-right", "--count", upstream+"...HEAD")
	if err != nil {
		return dirty, 0, 0, upstream
	}
	behind, ahead := parseAheadBehindCounts(counts)
	return dirty, ahead, behind, upstream
}

func parseAheadBehindCounts(output string) (int, int) {
	fields := strings.Fields(output)
	if len(fields) < 2 {
		return 0, 0
	}
	behind, _ := strconv.Atoi(fields[0])
	ahead, _ := strconv.Atoi(fields[1])
	return ahead, behind
}

func (r *Router) worktreesRoot() (string, error) {
	if value := strings.TrimSpace(r.cfg.WorktreesRoot); value != "" {
		abs, err := filepath.Abs(value)
		if err != nil {
			return "", fmt.Errorf("解析 worktrees_root 失败：%w", err)
		}
		return abs, nil
	}
	dir, err := config.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("定位用户配置目录失败：%w", err)
	}
	return filepath.Join(dir, "worktrees"), nil
}

func (r *Router) worktreeBranchList(ctx context.Context, realPath string) (worktreeBranchListResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, gitStatusCommandTimeout)
	defer cancel()

	response := worktreeBranchListResponse{
		Path:     realPath,
		Branches: []worktreeBranchItem{},
	}
	if _, err := exec.LookPath("git"); err != nil {
		return response, fmt.Errorf("git 不可用：%w", err)
	}
	repoRoot, _, err := runGitReadOnly(ctx, realPath, 16*1024, "rev-parse", "--show-toplevel")
	if err != nil {
		if isGitRepositoryMissingError(err) {
			return response, nil
		}
		return response, err
	}
	repoRoot = strings.TrimSpace(repoRoot)
	if repoRoot == "" {
		return response, nil
	}

	currentBranch, _, _ := runGitReadOnly(ctx, repoRoot, 4*1024, "branch", "--show-current")
	response.CurrentBranch = strings.TrimSpace(currentBranch)
	remoteDefault := worktreeRemoteDefaultBranch(ctx, repoRoot)

	// 分支列表只读本机已有 refs，不自动 fetch；移动端展示建议值，但仍允许用户手填任何有效 base。
	items := map[string]worktreeBranchItem{}
	if localOutput, _, err := runGitReadOnly(ctx, repoRoot, 64*1024, "branch", "--format=%(refname:short)|%(HEAD)"); err == nil {
		addWorktreeBranches(items, localOutput, "local", response.CurrentBranch)
	}
	if remoteOutput, _, err := runGitReadOnly(ctx, repoRoot, 64*1024, "branch", "-r", "--format=%(refname:short)|%(HEAD)"); err == nil {
		addWorktreeBranches(items, remoteOutput, "remote", "")
	}

	branches := make([]worktreeBranchItem, 0, len(items))
	for _, item := range items {
		branches = append(branches, item)
	}
	sortWorktreeBranches(branches)
	response.DefaultBase = defaultWorktreeBase(response.CurrentBranch, remoteDefault, branches)
	for i := range branches {
		branches[i].IsDefault = branches[i].Name == response.DefaultBase
	}
	response.Branches = branches
	return response, nil
}

func addWorktreeBranches(items map[string]worktreeBranchItem, output string, kind string, currentBranch string) {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 2)
		name := strings.TrimSpace(parts[0])
		if name == "" || strings.Contains(name, " -> ") || strings.HasSuffix(name, "/HEAD") {
			continue
		}
		key := kind + ":" + name
		if _, exists := items[key]; exists {
			continue
		}
		isCurrent := kind == "local" && name == currentBranch
		if len(parts) > 1 && strings.TrimSpace(parts[1]) == "*" {
			isCurrent = true
		}
		items[key] = worktreeBranchItem{
			Name:      name,
			Kind:      kind,
			IsCurrent: isCurrent,
		}
	}
}

func sortWorktreeBranches(branches []worktreeBranchItem) {
	sort.Slice(branches, func(i, j int) bool {
		if branches[i].IsCurrent != branches[j].IsCurrent {
			return branches[i].IsCurrent
		}
		if branches[i].Kind != branches[j].Kind {
			return branches[i].Kind == "local"
		}
		return branches[i].Name < branches[j].Name
	})
}

func worktreeRemoteDefaultBranch(ctx context.Context, repoRoot string) string {
	output, _, err := runGitReadOnly(ctx, repoRoot, 4*1024, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(output)
}

func defaultWorktreeBase(currentBranch string, remoteDefault string, branches []worktreeBranchItem) string {
	if currentBranch != "" {
		return currentBranch
	}
	if remoteDefault != "" {
		return remoteDefault
	}
	for _, preferred := range []string{"main", "master", "origin/main", "origin/master"} {
		for _, item := range branches {
			if item.Name == preferred {
				return item.Name
			}
		}
	}
	if len(branches) > 0 {
		return branches[0].Name
	}
	return ""
}

func normalizedWorktreeBase(base string) (string, error) {
	value := strings.TrimSpace(base)
	if value == "" {
		return "", fmt.Errorf("base 不能为空")
	}
	if strings.ContainsRune(value, '\x00') || strings.HasPrefix(value, "-") || strings.ContainsAny(value, " \t\r\n") {
		return "", fmt.Errorf("base 不是安全的 Git 引用")
	}
	if len([]rune(value)) > 160 {
		return "", fmt.Errorf("base 过长")
	}
	return value, nil
}

func (r *Router) worktreeBranchName(ctx context.Context, repoRoot string, requested string, fallback string, timestamp string) (string, error) {
	if branch := strings.TrimSpace(requested); branch != "" {
		if err := validateWorktreeBranchName(ctx, repoRoot, branch); err != nil {
			return "", err
		}
		if worktreeBranchExists(ctx, repoRoot, branch) {
			return "", fmt.Errorf("branch 已存在：%s", branch)
		}
		return branch, nil
	}

	slug := sanitizedWorktreeBranchSlug(fallback)
	for i := 1; i <= 100; i++ {
		name := fmt.Sprintf("mimi/%s-%s", slug, timestamp)
		if i > 1 {
			name = fmt.Sprintf("mimi/%s-%s-%d", slug, timestamp, i)
		}
		if err := validateWorktreeBranchName(ctx, repoRoot, name); err != nil {
			return "", err
		}
		if worktreeBranchExists(ctx, repoRoot, name) {
			continue
		}
		return name, nil
	}
	return "", fmt.Errorf("无法生成唯一 Worktree 分支名")
}

func validateWorktreeBranchName(ctx context.Context, repoRoot string, branch string) error {
	value := strings.TrimSpace(branch)
	if value == "" {
		return fmt.Errorf("branch 不能为空")
	}
	if strings.ContainsRune(value, '\x00') || strings.HasPrefix(value, "-") || strings.ContainsAny(value, " \t\r\n") {
		return fmt.Errorf("branch 不是安全的 Git 分支名")
	}
	if _, _, err := runGitReadOnly(ctx, repoRoot, 4*1024, "check-ref-format", "--branch", value); err != nil {
		return fmt.Errorf("branch 不是有效 Git 分支名：%w", err)
	}
	return nil
}

func worktreeBranchExists(ctx context.Context, repoRoot string, branch string) bool {
	_, _, err := runGitReadOnly(ctx, repoRoot, 4*1024, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil
}

func sanitizedWorktreeBranchSlug(raw string) string {
	slug := sanitizedWorktreeName(raw)
	slug = strings.Trim(slug, ".")
	if slug == "" {
		return "worktree"
	}
	return slug
}

func sanitizedWorktreeName(raw string) string {
	value := strings.TrimSpace(raw)
	var b strings.Builder
	lastDash := false
	for _, r := range value {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(unicode.ToLower(r))
			lastDash = false
		case r == '-' || r == '_' || r == '.':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash {
				b.WriteByte('-')
				lastDash = true
			}
		}
	}
	out := strings.Trim(b.String(), "-_.")
	if out == "" {
		return "worktree"
	}
	if len([]rune(out)) > 48 {
		return string([]rune(out)[:48])
	}
	return out
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
