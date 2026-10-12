# SimulateKeyboardInput

Windows 工具：选取文本文件后，用全局快捷键把内容模拟为键盘输入到当前光标处。无需 .NET SDK，使用系统自带的 Windows PowerShell 和 WinForms。

## 使用

1. 双击 `Run.bat` 启动。
2. 点击“选择文件...”。需要时点击“修改快捷键”，按下含 Ctrl、Alt 或 Shift 的组合键，再点“保存”。快捷键会保存到当前 Windows 用户配置，下次启动继续使用。
3. 切换到目标输入位置，按显示的快捷键。工具必须保持运行，不必置于前台。

## 输入行为

- CRLF、LF、CR 换行均模拟为一次 Enter；制表符模拟为 Tab。
- 其它字符通过 Unicode 键盘输入发送；控制字符的表现取决于目标程序。
- 支持 UTF-8（含/不含 BOM）和带 BOM 的 UTF-16/UTF-32；无 BOM 且不是有效 UTF-8 的文件按 Windows 系统 ANSI 编码读取。
- 如果快捷键冲突，状态栏会提示；管理员权限运行的目标程序通常要求本工具也以管理员身份运行。

`Run.bat` 仅为启动的 PowerShell 进程指定执行策略，不会修改系统或用户的持久设置。
