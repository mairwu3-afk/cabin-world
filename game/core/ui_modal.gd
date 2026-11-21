class_name UiModal
## 手机触摸守卫：任何打开的全屏面板（设置、聊天、编辑器）都加入 ui_modal 组。
## 世界的 _input 处理器（entities/room_camera.gd 等）在 Godot 里比 GUI 先收到手指事件，
## 手指抖动几像素就会被当成拖动并吃掉抬起事件，弹窗按钮就"点不动"。
## 所以这些处理器在动之前先问这里：有面板开着就让路，事件继续交给 GUI。


static func is_open(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group("ui_modal"):
		if node is Control:
			if node.visible:
				return true
		else:
			## CanvasLayer 等非 Control 节点：用 get() 取 visible，取不到就当它开着（宁可让路）
			var shown = node.get("visible")
			if shown == null or bool(shown):
				return true
	return false
