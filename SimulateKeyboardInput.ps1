param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('SimulateKeyboardInput.KeyboardInput' -as [type])) {
    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Drawing;

namespace SimulateKeyboardInput
{
    public sealed class Stroke
    {
        public ushort VirtualKey { get; private set; }
        public ushort ScanCode { get; private set; }
        public uint Flags { get; private set; }

        internal Stroke(ushort virtualKey, ushort scanCode, uint flags)
        {
            VirtualKey = virtualKey;
            ScanCode = scanCode;
            Flags = flags;
        }
    }

    public sealed class ShortcutConfiguration
    {
        public const uint ModifierAlt = 0x0001;
        public const uint ModifierControl = 0x0002;
        public const uint ModifierShift = 0x0004;

        public uint Modifiers { get; private set; }
        public uint VirtualKey { get; private set; }

        private static string SettingsPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "SimulateKeyboardInput",
                    "shortcut.conf");
            }
        }

        internal ShortcutConfiguration(uint modifiers, uint virtualKey)
        {
            if (!IsValid(modifiers, virtualKey))
                throw new ArgumentException("The shortcut must include a modifier and a non-modifier key.");
            Modifiers = modifiers;
            VirtualKey = virtualKey;
        }

        public static ShortcutConfiguration CreateDefault()
        {
            return new ShortcutConfiguration(ModifierControl | ModifierAlt, (uint)Keys.I);
        }

        public static ShortcutConfiguration Load()
        {
            return LoadFrom(SettingsPath);
        }

        public static ShortcutConfiguration LoadFrom(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    ShortcutConfiguration saved = Parse(File.ReadAllText(path));
                    if (saved != null)
                        return saved;
                }
            }
            catch
            {
                // A missing or unreadable settings file falls back to the default shortcut.
            }
            return CreateDefault();
        }

        public static ShortcutConfiguration Parse(string value)
        {
            if (String.IsNullOrWhiteSpace(value))
                return null;
            string[] parts = value.Trim().Split('|');
            uint modifiers;
            uint virtualKey;
            if (parts.Length != 2 ||
                !UInt32.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out modifiers) ||
                !UInt32.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out virtualKey) ||
                !IsValid(modifiers, virtualKey))
                return null;
            return new ShortcutConfiguration(modifiers, virtualKey);
        }

        public void Save()
        {
            SaveTo(SettingsPath);
        }

        public void SaveTo(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A settings path is required.", "path");
            path = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporaryPath = path + ".tmp";
            try
            {
                string value = Modifiers.ToString(CultureInfo.InvariantCulture) + "|" +
                    VirtualKey.ToString(CultureInfo.InvariantCulture);
                File.WriteAllText(temporaryPath, value, new UTF8Encoding(false));
                if (File.Exists(path))
                    File.Replace(temporaryPath, path, null);
                else
                    File.Move(temporaryPath, path);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
        }

        public string DisplayText()
        {
            List<string> parts = new List<string>();
            if ((Modifiers & ModifierControl) != 0)
                parts.Add("Ctrl");
            if ((Modifiers & ModifierAlt) != 0)
                parts.Add("Alt");
            if ((Modifiers & ModifierShift) != 0)
                parts.Add("Shift");
            parts.Add(((Keys)VirtualKey).ToString());
            return String.Join("+", parts.ToArray());
        }

        private static bool IsValid(uint modifiers, uint virtualKey)
        {
            uint validModifiers = ModifierAlt | ModifierControl | ModifierShift;
            if (modifiers == 0 || (modifiers & ~validModifiers) != 0 || virtualKey == 0 || virtualKey > 255)
                return false;

            Keys key = (Keys)virtualKey;
            return key != Keys.ControlKey && key != Keys.ShiftKey && key != Keys.Menu &&
                key != Keys.LControlKey && key != Keys.RControlKey &&
                key != Keys.LShiftKey && key != Keys.RShiftKey &&
                key != Keys.LMenu && key != Keys.RMenu;
        }
    }

    public static class KeyboardInput
    {
        public const uint KeyEventExtended = 0x0001;
        public const uint KeyEventKeyUp = 0x0002;
        public const uint KeyEventUnicode = 0x0004;
        public const uint KeyEventScanCode = 0x0008;
        private const uint MapVirtualKeyToScanCodeEx = 4;
        private const uint InputKeyboard = 1;
        private const ushort VkTab = 0x09;
        private const ushort VkReturn = 0x0D;
        private const int BatchSize = 512;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeInput
        {
            public uint Type;
            public InputUnion Union;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)]
            public MouseData Mouse;

            [FieldOffset(0)]
            public KeyboardData Keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseData
        {
            public int X;
            public int Y;
            public uint MouseDataValue;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardData
        {
            public ushort VirtualKey;
            public ushort ScanCode;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint inputCount, NativeInput[] inputs, int inputSize);

        [DllImport("user32.dll")]
        private static extern uint MapVirtualKey(uint virtualKey, uint mapType);

        public static string ReadText(string path)
        {
            return DecodeBytes(File.ReadAllBytes(path));
        }

        public static string DecodeBytes(byte[] bytes)
        {
            if (bytes == null)
                throw new ArgumentNullException("bytes");

            if (StartsWith(bytes, 0xFF, 0xFE, 0x00, 0x00))
                return Encoding.UTF32.GetString(bytes, 4, bytes.Length - 4);
            if (StartsWith(bytes, 0x00, 0x00, 0xFE, 0xFF))
                return new UTF32Encoding(true, false, true).GetString(bytes, 4, bytes.Length - 4);
            if (StartsWith(bytes, 0xEF, 0xBB, 0xBF))
                return new UTF8Encoding(false, true).GetString(bytes, 3, bytes.Length - 3);
            if (StartsWith(bytes, 0xFF, 0xFE))
                return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
            if (StartsWith(bytes, 0xFE, 0xFF))
                return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);

            try
            {
                return new UTF8Encoding(false, true).GetString(bytes);
            }
            catch (DecoderFallbackException)
            {
                return Encoding.Default.GetString(bytes);
            }
        }

        private static bool StartsWith(byte[] bytes, params byte[] prefix)
        {
            if (bytes.Length < prefix.Length)
                return false;
            for (int i = 0; i < prefix.Length; i++)
            {
                if (bytes[i] != prefix[i])
                    return false;
            }
            return true;
        }

        public static List<Stroke> BuildStrokes(string text)
        {
            List<Stroke> result = new List<Stroke>();
            ForEachKey(text, delegate(ushort virtualKey, ushort scanCode, uint flags)
            {
                result.Add(new Stroke(virtualKey, scanCode, flags));
                result.Add(new Stroke(virtualKey, scanCode, flags | KeyEventKeyUp));
            });
            return result;
        }

        public static void SendText(string text)
        {
            List<NativeInput> batch = new List<NativeInput>(BatchSize);
            ForEachKey(text, delegate(ushort virtualKey, ushort scanCode, uint flags)
            {
                batch.Add(CreateInput(virtualKey, scanCode, flags));
                batch.Add(CreateInput(virtualKey, scanCode, flags | KeyEventKeyUp));
                if (batch.Count >= BatchSize)
                    SendBatch(batch);
            });
            SendBatch(batch);
        }

        public static bool SendTextCancellable(string text, Func<bool> cancellationRequested)
        {
            if (cancellationRequested == null)
                cancellationRequested = delegate { return false; };

            List<NativeInput> batch = new List<NativeInput>(BatchSize);
            bool completed = ForEachCharacter(text, delegate(char first, char second, int codeUnitCount)
            {
                if (cancellationRequested())
                    return false;

                if (first == '\r')
                    AddKeyPair(batch, VkReturn, 0, 0);
                else if (first == '\t')
                    AddKeyPair(batch, VkTab, 0, 0);
                else
                {
                    for (int i = 0; i < codeUnitCount; i++)
                    {
                        char current = i == 0 ? first : second;
                        AddKeyPair(batch, 0, current, KeyEventUnicode);
                    }
                }

                if (batch.Count >= BatchSize)
                    SendBatch(batch);
                return true;
            });
            if (!completed || cancellationRequested())
                return false;
            SendBatch(batch);
            return true;
        }

        public static void SendKeyChord(string chord)
        {
            List<Stroke> strokes = BuildKeyChordStrokes(chord);
            List<NativeInput> inputs = new List<NativeInput>(strokes.Count);
            for (int i = 0; i < strokes.Count; i++)
                inputs.Add(CreateInput(strokes[i].VirtualKey, strokes[i].ScanCode, strokes[i].Flags));
            SendBatch(inputs);
        }

        public static List<Stroke> BuildKeyChordStrokes(string chord)
        {
            List<Keys> keys = ManualProgramValidator.ParseKeyChord(chord);
            List<Stroke> strokes = new List<Stroke>(keys.Count * 2);
            for (int i = 0; i < keys.Count; i++)
                strokes.Add(BuildKeyStroke((ushort)keys[i], false));
            for (int i = keys.Count - 1; i >= 0; i--)
                strokes.Add(BuildKeyStroke((ushort)keys[i], true));
            return strokes;
        }

        private static Stroke BuildKeyStroke(ushort virtualKey, bool keyUp)
        {
            ushort extendedScanCode;
            if (TryGetExtendedScanCode(virtualKey, out extendedScanCode))
            {
                uint extendedFlags = KeyEventScanCode | KeyEventExtended;
                if (keyUp)
                    extendedFlags |= KeyEventKeyUp;
                return new Stroke(0, extendedScanCode, extendedFlags);
            }

            uint mappedScanCode = MapVirtualKey(virtualKey, MapVirtualKeyToScanCodeEx);
            uint prefix = mappedScanCode & 0xFF00;
            if (mappedScanCode != 0 && prefix == 0xE000)
            {
                uint flags = KeyEventScanCode | KeyEventExtended;
                if (keyUp)
                    flags |= KeyEventKeyUp;
                return new Stroke(0, (ushort)(mappedScanCode & 0xFF), flags);
            }

            uint virtualKeyFlags = IsExtendedVirtualKey(virtualKey) ? KeyEventExtended : 0;
            if (keyUp)
                virtualKeyFlags |= KeyEventKeyUp;
            return new Stroke(virtualKey, 0, virtualKeyFlags);
        }

        private static bool TryGetExtendedScanCode(ushort virtualKey, out ushort scanCode)
        {
            switch (virtualKey)
            {
                case 0x21: scanCode = 0x49; return true; // Page Up (E0 49)
                case 0x22: scanCode = 0x51; return true; // Page Down (E0 51)
                case 0x23: scanCode = 0x4F; return true; // End (E0 4F)
                case 0x24: scanCode = 0x47; return true; // Home (E0 47)
                case 0x25: scanCode = 0x4B; return true; // Left (E0 4B)
                case 0x26: scanCode = 0x48; return true; // Up (E0 48)
                case 0x27: scanCode = 0x4D; return true; // Right (E0 4D)
                case 0x28: scanCode = 0x50; return true; // Down (E0 50)
                case 0x2C: scanCode = 0x37; return true; // Print Screen (E0 37)
                case 0x2D: scanCode = 0x52; return true; // Insert (E0 52)
                case 0x2E: scanCode = 0x53; return true; // Delete (E0 53)
                case 0x5B: scanCode = 0x5B; return true; // Left Windows (E0 5B)
                case 0x5C: scanCode = 0x5C; return true; // Right Windows (E0 5C)
                case 0x5D: scanCode = 0x5D; return true; // Applications (E0 5D)
                case 0x6F: scanCode = 0x35; return true; // Keypad Divide (E0 35)
                case 0x90: scanCode = 0x45; return true; // Num Lock (E0 45)
                default:
                    scanCode = 0;
                    return false;
            }
        }

        private static bool IsExtendedVirtualKey(ushort virtualKey)
        {
            switch (virtualKey)
            {
                case 0x21: // Page Up
                case 0x22: // Page Down
                case 0x23: // End
                case 0x24: // Home
                case 0x25: // Left
                case 0x26: // Up
                case 0x27: // Right
                case 0x28: // Down
                case 0x2C: // Print Screen
                case 0x2D: // Insert
                case 0x2E: // Delete
                case 0x5B: // Left Windows
                case 0x5C: // Right Windows
                case 0x5D: // Applications
                case 0x6F: // Keypad Divide
                case 0x90: // Num Lock
                    return true;
                default:
                    return false;
            }
        }

        public static bool SendTextWithInterval(string text, int intervalMilliseconds, Func<bool> cancellationRequested)
        {
            return ForEachCharacterWithInterval(text, intervalMilliseconds, cancellationRequested,
                delegate(char first, char second, int codeUnitCount)
            {
                List<NativeInput> inputs = new List<NativeInput>(4);
                if (first == '\r')
                {
                    AddKeyPair(inputs, VkReturn, 0, 0);
                }
                else if (first == '\t')
                {
                    AddKeyPair(inputs, VkTab, 0, 0);
                }
                else
                {
                    for (int i = 0; i < codeUnitCount; i++)
                    {
                        char current = i == 0 ? first : second;
                        AddKeyPair(inputs, 0, current, KeyEventUnicode);
                    }
                }

                SendBatch(inputs);
            },
                delegate(int milliseconds) { Thread.Sleep(milliseconds); });
        }

        private static bool ForEachCharacterWithInterval(string text, int intervalMilliseconds,
            Func<bool> cancellationRequested, Action<char, char, int> emitCharacter, Action<int> wait)
        {
            if (intervalMilliseconds < 1 || intervalMilliseconds > 1000)
                throw new ArgumentOutOfRangeException("intervalMilliseconds", "The character interval must be between 1 and 1000 milliseconds.");
            if (cancellationRequested == null)
                cancellationRequested = delegate { return false; };
            if (emitCharacter == null)
                throw new ArgumentNullException("emitCharacter");
            if (wait == null)
                throw new ArgumentNullException("wait");

            int sentCharacters = 0;
            return ForEachCharacter(text, delegate(char first, char second, int codeUnitCount)
            {
                if (cancellationRequested())
                    return false;
                if (sentCharacters > 0)
                {
                    wait(intervalMilliseconds);
                    if (cancellationRequested())
                        return false;
                }

                emitCharacter(first, second, codeUnitCount);
                sentCharacters++;
                return true;
            });
        }

        private static void AddKeyPair(List<NativeInput> inputs, ushort virtualKey, ushort scanCode, uint flags)
        {
            inputs.Add(CreateInput(virtualKey, scanCode, flags));
            inputs.Add(CreateInput(virtualKey, scanCode, flags | KeyEventKeyUp));
        }

        private static bool ForEachCharacter(string text, Func<char, char, int, bool> emit)
        {
            if (text == null)
                throw new ArgumentNullException("text");

            for (int i = 0; i < text.Length; i++)
            {
                char current = text[i];
                if (current == '\r')
                {
                    if (i + 1 < text.Length && text[i + 1] == '\n')
                        i++;
                    if (!emit('\r', '\0', 1))
                        return false;
                }
                else if (current == '\n')
                {
                    if (!emit('\r', '\0', 1))
                        return false;
                }
                else if (current == '\t')
                {
                    if (!emit('\t', '\0', 1))
                        return false;
                }
                else if (Char.IsHighSurrogate(current) && i + 1 < text.Length && Char.IsLowSurrogate(text[i + 1]))
                {
                    if (!emit(current, text[++i], 2))
                        return false;
                }
                else if (!emit(current, '\0', 1))
                {
                    return false;
                }
            }
            return true;
        }

        private static int CountLogicalCharacters(string text)
        {
            int count = 0;
            ForEachCharacter(text, delegate(char first, char second, int codeUnitCount)
            {
                count++;
                return true;
            });
            return count;
        }

        private static void ForEachKey(string text, Action<ushort, ushort, uint> emit)
        {
            if (text == null)
                throw new ArgumentNullException("text");

            for (int i = 0; i < text.Length; i++)
            {
                char current = text[i];
                if (current == '\r')
                {
                    if (i + 1 < text.Length && text[i + 1] == '\n')
                        i++;
                    emit(VkReturn, 0, 0);
                }
                else if (current == '\n')
                {
                    emit(VkReturn, 0, 0);
                }
                else if (current == '\t')
                {
                    emit(VkTab, 0, 0);
                }
                else
                {
                    emit(0, current, KeyEventUnicode);
                }
            }
        }

        private static NativeInput CreateInput(ushort virtualKey, ushort scanCode, uint flags)
        {
            NativeInput input = new NativeInput();
            input.Type = InputKeyboard;
            input.Union.Keyboard = new KeyboardData
            {
                VirtualKey = virtualKey,
                ScanCode = scanCode,
                Flags = flags,
                Time = 0,
                ExtraInfo = UIntPtr.Zero
            };
            return input;
        }

        private static void SendBatch(List<NativeInput> batch)
        {
            if (batch.Count == 0)
                return;

            NativeInput[] inputs = batch.ToArray();
            uint inserted = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(NativeInput)));
            if (inserted != inputs.Length)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error,
                    "Windows did not accept all simulated keyboard input. The target may be elevated or may block injected input.");
            }
            batch.Clear();
        }

        public static string RunSelfTests()
        {
            int expectedInputSize = IntPtr.Size == 8 ? 40 : 28;
            Assert(Marshal.SizeOf(typeof(NativeInput)) == expectedInputSize,
                "Native INPUT structure has an unexpected size for this architecture.");

            List<Stroke> strokes = BuildStrokes("A\tB\r\nC\nD\rE");
            Assert(strokes.Count == 18, "CRLF must produce one Enter; LF and CR must each produce one Enter.");
            AssertKey(strokes, 0, 0, (ushort)'A', KeyEventUnicode);
            AssertKey(strokes, 1, VkTab, 0, 0);
            AssertKey(strokes, 2, 0, (ushort)'B', KeyEventUnicode);
            AssertKey(strokes, 3, VkReturn, 0, 0);
            AssertKey(strokes, 4, 0, (ushort)'C', KeyEventUnicode);
            AssertKey(strokes, 5, VkReturn, 0, 0);
            AssertKey(strokes, 6, 0, (ushort)'D', KeyEventUnicode);
            AssertKey(strokes, 7, VkReturn, 0, 0);
            AssertKey(strokes, 8, 0, (ushort)'E', KeyEventUnicode);

            string supplementaryCharacter = new string(new char[] { (char)0xD83D, (char)0xDE00 });
            List<Stroke> unicodeStrokes = BuildStrokes("A" + supplementaryCharacter + "Z");
            Assert(unicodeStrokes.Count == 8, "UTF-16 surrogate pairs must be preserved.");
            AssertKey(unicodeStrokes, 1, 0, 0xD83D, KeyEventUnicode);
            AssertKey(unicodeStrokes, 2, 0, 0xDE00, KeyEventUnicode);
            Assert(CountLogicalCharacters("A\tB\r\nC\nD\rE") == 9,
                "Tabs and line endings must each count as one delayed character.");
            Assert(CountLogicalCharacters("A" + supplementaryCharacter + "Z") == 3,
                "A surrogate pair must count as one delayed character.");
            int emittedCharacters = 0;
            List<int> requestedIntervals = new List<int>();
            bool intervalSendCompleted = ForEachCharacterWithInterval("A" + supplementaryCharacter + "B", 25,
                delegate { return false; },
                delegate(char first, char second, int codeUnitCount) { emittedCharacters++; },
                delegate(int milliseconds) { requestedIntervals.Add(milliseconds); });
            Assert(intervalSendCompleted && emittedCharacters == 3 && requestedIntervals.Count == 2 &&
                requestedIntervals[0] == 25 && requestedIntervals[1] == 25,
                "The configured delay must run exactly once between logical characters, not after the final character.");
            Assert(!SendTextWithInterval("A", 1, delegate { return true; }),
                "A cancellation request must stop before sending the first character.");
            bool invalidIntervalRejected = false;
            try
            {
                SendTextWithInterval("", 0, null);
            }
            catch (ArgumentOutOfRangeException)
            {
                invalidIntervalRejected = true;
            }
            Assert(invalidIntervalRejected, "Character intervals outside 1-1000 ms must be rejected.");

            string sample = "\u6587\u672c\t\u503c\r\n";
            Assert(DecodeBytes(Encoding.UTF8.GetBytes(sample)) == sample, "BOM-less UTF-8 decoding failed.");
            Assert(DecodeBytes(WithBom(Encoding.UTF8, sample)) == sample, "UTF-8 BOM decoding failed.");
            Assert(DecodeBytes(WithBom(Encoding.Unicode, sample)) == sample, "UTF-16 BOM decoding failed.");

            ShortcutConfiguration savedShortcut = ShortcutConfiguration.Parse("3|73");
            Assert(savedShortcut != null && savedShortcut.DisplayText() == "Ctrl+Alt+I",
                "Saved shortcut settings did not round-trip.");
            Assert(ShortcutConfiguration.Parse("0|73") == null,
                "A shortcut without a modifier must be rejected.");

            string temporarySettings = Path.Combine(Path.GetTempPath(),
                "SimulateKeyboardInput-selftest-" + Guid.NewGuid().ToString("N") + ".conf");
            try
            {
                savedShortcut.SaveTo(temporarySettings);
                ShortcutConfiguration updatedShortcut = new ShortcutConfiguration(
                    ShortcutConfiguration.ModifierControl | ShortcutConfiguration.ModifierShift,
                    (uint)Keys.K);
                updatedShortcut.SaveTo(temporarySettings);
                ShortcutConfiguration loadedShortcut = ShortcutConfiguration.LoadFrom(temporarySettings);
                Assert(loadedShortcut != null && loadedShortcut.DisplayText() == "Ctrl+Shift+K",
                    "Persisted shortcut settings did not survive a save and reload.");
            }
            finally
            {
                if (File.Exists(temporarySettings))
                    File.Delete(temporarySettings);
            }

            return "Self-test passed: native INPUT size, text decoding, Unicode, tabs, line endings, shortcut persistence, and character interval handling.";
        }

        private static byte[] WithBom(Encoding encoding, string text)
        {
            byte[] prefix = encoding.GetPreamble();
            byte[] content = encoding.GetBytes(text);
            byte[] result = new byte[prefix.Length + content.Length];
            Buffer.BlockCopy(prefix, 0, result, 0, prefix.Length);
            Buffer.BlockCopy(content, 0, result, prefix.Length, content.Length);
            return result;
        }

        private static void AssertKey(List<Stroke> strokes, int keyIndex, ushort virtualKey, ushort scanCode, uint flags)
        {
            int index = keyIndex * 2;
            Assert(strokes[index].VirtualKey == virtualKey, "Unexpected virtual key at index " + keyIndex + ".");
            Assert(strokes[index].ScanCode == scanCode, "Unexpected scan code at index " + keyIndex + ".");
            Assert(strokes[index].Flags == flags, "Unexpected key-down flags at index " + keyIndex + ".");
            Assert(strokes[index + 1].VirtualKey == virtualKey, "Unexpected key-up virtual key at index " + keyIndex + ".");
            Assert(strokes[index + 1].ScanCode == scanCode, "Unexpected key-up scan code at index " + keyIndex + ".");
            Assert(strokes[index + 1].Flags == (flags | KeyEventKeyUp), "Unexpected key-up flags at index " + keyIndex + ".");
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition)
                throw new InvalidOperationException(message);
        }
    }

    [DataContract]
    public sealed class ManualProgram
    {
        [DataMember(Order = 1)]
        public int Version { get; set; }

        [DataMember(Order = 2)]
        public List<ManualBlock> Blocks { get; set; }

        public ManualProgram()
        {
            Version = 1;
            Blocks = new List<ManualBlock>();
        }
    }

    [DataContract]
    public sealed class ManualBlock
    {
        public const string Text = "text";
        public const string Key = "key";
        public const string Wait = "wait";
        public const string Loop = "loop";

        [DataMember(Order = 1)]
        public string Type { get; set; }

        [DataMember(Order = 2, EmitDefaultValue = false)]
        public string Value { get; set; }

        [DataMember(Order = 3, EmitDefaultValue = false)]
        public double Seconds { get; set; }

        [DataMember(Order = 4, EmitDefaultValue = false)]
        public int MaxIterations { get; set; }

        [DataMember(Order = 5, EmitDefaultValue = false)]
        public double MaxDurationSeconds { get; set; }

        [DataMember(Order = 6, EmitDefaultValue = false)]
        public List<ManualBlock> Children { get; set; }

        public ManualBlock()
        {
            Children = new List<ManualBlock>();
        }
    }

    public static class ManualProgramValidator
    {
        private const int MaximumBlocks = 1000;
        private const int MaximumDepth = 16;

        public static void Validate(ManualProgram program, bool forExecution)
        {
            if (program == null)
                throw new InvalidDataException("\u64cd\u4f5c\u6d41\u7a0b\u4e3a\u7a7a\u3002");
            if (program.Version != 1)
                throw new InvalidDataException("\u4e0d\u652f\u6301\u7684 JSON \u6d41\u7a0b\u7248\u672c\uff1a" + program.Version + "\u3002");
            if (program.Blocks == null)
                throw new InvalidDataException("JSON \u6d41\u7a0b\u7f3a\u5c11\u79ef\u6728\u5217\u8868\u3002");
            if (forExecution && program.Blocks.Count == 0)
                throw new InvalidDataException("\u8bf7\u5148\u6dfb\u52a0\u81f3\u5c11\u4e00\u4e2a\u64cd\u4f5c\u79ef\u6728\u3002");

            int blockCount = 0;
            ValidateBlocks(program.Blocks, 0, forExecution, ref blockCount);
        }

        private static void ValidateBlocks(List<ManualBlock> blocks, int depth, bool forExecution, ref int blockCount)
        {
            if (depth > MaximumDepth)
                throw new InvalidDataException("\u5faa\u73af\u5d4c\u5957\u4e0d\u80fd\u8d85\u8fc7 " + MaximumDepth + " \u5c42\u3002");

            for (int i = 0; i < blocks.Count; i++)
            {
                ManualBlock block = blocks[i];
                blockCount++;
                if (blockCount > MaximumBlocks)
                    throw new InvalidDataException("\u4e00\u4e2a\u6d41\u7a0b\u6700\u591a\u5305\u542b " + MaximumBlocks + " \u4e2a\u79ef\u6728\u3002");
                if (block == null)
                    throw new InvalidDataException("\u6d41\u7a0b\u4e2d\u5305\u542b\u7a7a\u79ef\u6728\u3002");

                if (block.Type == ManualBlock.Text)
                {
                    if (block.Value == null)
                        block.Value = String.Empty;
                    if (block.Value.Length > 100000)
                        throw new InvalidDataException("\u5355\u4e2a\u8f93\u5165\u5185\u5bb9\u4e0d\u80fd\u8d85\u8fc7 100000 \u4e2a\u5b57\u7b26\u3002");
                    if (forExecution && block.Value.Length == 0)
                        throw new InvalidDataException("\u8f93\u5165\u5185\u5bb9\u79ef\u6728\u4e0d\u80fd\u4e3a\u7a7a\u3002");
                    if (block.Children != null && block.Children.Count != 0)
                        throw new InvalidDataException("\u8f93\u5165\u5185\u5bb9\u79ef\u6728\u4e0d\u80fd\u5305\u542b\u5176\u4ed6\u79ef\u6728\u3002");
                }
                else if (block.Type == ManualBlock.Key)
                {
                    if (block.Value == null)
                        block.Value = String.Empty;
                    if (block.Value.Length > 100)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u5185\u5bb9\u8fc7\u957f\u3002");
                    if (forExecution || block.Value.Length > 0)
                    {
                        ParseKeyChord(block.Value);
                    }
                    if (block.Children != null && block.Children.Count != 0)
                        throw new InvalidDataException("\u6309\u952e\u79ef\u6728\u4e0d\u80fd\u5305\u542b\u5176\u4ed6\u79ef\u6728\u3002");
                }
                else if (block.Type == ManualBlock.Wait)
                {
                    if (Double.IsNaN(block.Seconds) || Double.IsInfinity(block.Seconds) ||
                        block.Seconds < 0.01 || block.Seconds > 3600)
                        throw new InvalidDataException("\u7b49\u5f85\u65f6\u95f4\u5fc5\u987b\u5728 0.01 \u5230 3600 \u79d2\u4e4b\u95f4\u3002");
                    if (block.Children != null && block.Children.Count != 0)
                        throw new InvalidDataException("\u7b49\u5f85\u79ef\u6728\u4e0d\u80fd\u5305\u542b\u5176\u4ed6\u79ef\u6728\u3002");
                }
                else if (block.Type == ManualBlock.Loop)
                {
                    if (block.MaxIterations < 0 || block.MaxIterations > 1000000)
                        throw new InvalidDataException("\u5faa\u73af\u6b21\u6570\u5fc5\u987b\u5728 0 \u5230 1000000 \u4e4b\u95f4\u3002");
                    if (Double.IsNaN(block.MaxDurationSeconds) || Double.IsInfinity(block.MaxDurationSeconds) ||
                        block.MaxDurationSeconds < 0 || block.MaxDurationSeconds > 86400)
                        throw new InvalidDataException("\u5faa\u73af\u8fd0\u884c\u65f6\u95f4\u5fc5\u987b\u5728 0 \u5230 86400 \u79d2\u4e4b\u95f4\u3002");
                    if (forExecution && block.MaxIterations == 0 && block.MaxDurationSeconds == 0)
                        throw new InvalidDataException("\u6bcf\u4e2a\u5faa\u73af\u81f3\u5c11\u8981\u8bbe\u7f6e\u5faa\u73af\u6b21\u6570\u6216\u6700\u957f\u8fd0\u884c\u65f6\u95f4\u3002");
                    if (forExecution && (block.Children == null || block.Children.Count == 0))
                        throw new InvalidDataException("\u5faa\u73af\u4f53\u4e0d\u80fd\u4e3a\u7a7a\uff0c\u8bf7\u5148\u628a\u79ef\u6728\u653e\u5165\u5faa\u73af\u4f53\u3002");
                    if (block.Children == null)
                        block.Children = new List<ManualBlock>();
                    ValidateBlocks(block.Children, depth + 1, forExecution, ref blockCount);
                }
                else
                    throw new InvalidDataException("\u9047\u5230\u4e0d\u652f\u6301\u7684\u79ef\u6728\u7c7b\u578b\u3002");
            }
        }

        public static List<Keys> ParseKeyChord(string value)
        {
            if (String.IsNullOrWhiteSpace(value))
                throw new InvalidDataException("\u8bf7\u586b\u5199\u6709\u6548\u7684\u6309\u952e\u6216\u7ec4\u5408\u952e\uff0c\u4f8b\u5982 Ctrl+C\u3002");

            string[] parts = value.Split('+');
            bool control = false;
            bool alt = false;
            bool shift = false;
            Keys mainKey = Keys.None;
            for (int i = 0; i < parts.Length; i++)
            {
                string part = parts[i].Trim();
                if (part.Length == 0)
                    throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u683c\u5f0f\u65e0\u6548\uff0c\u8bf7\u4f7f\u7528\u4f8b\u5982 Ctrl+Shift+A \u7684\u683c\u5f0f\u3002");
                if (String.Equals(part, "Ctrl", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(part, "Control", StringComparison.OrdinalIgnoreCase))
                {
                    if (control)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u4e2d\u4e0d\u80fd\u91cd\u590d Ctrl\u3002");
                    control = true;
                    continue;
                }
                if (String.Equals(part, "Alt", StringComparison.OrdinalIgnoreCase))
                {
                    if (alt)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u4e2d\u4e0d\u80fd\u91cd\u590d Alt\u3002");
                    alt = true;
                    continue;
                }
                if (String.Equals(part, "Shift", StringComparison.OrdinalIgnoreCase))
                {
                    if (shift)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u4e2d\u4e0d\u80fd\u91cd\u590d Shift\u3002");
                    shift = true;
                    continue;
                }

                Keys parsed;
                if (part.IndexOf(',') >= 0 || part.IndexOf('|') >= 0 ||
                    !Enum.TryParse<Keys>(part, true, out parsed) || parsed == Keys.None ||
                    !Enum.IsDefined(typeof(Keys), parsed) || (int)parsed < 1 || (int)parsed > 255 ||
                    (((int)parsed & (int)Keys.Modifiers) != 0) ||
                    parsed == Keys.ControlKey || parsed == Keys.ShiftKey || parsed == Keys.Menu ||
                    parsed == Keys.LControlKey || parsed == Keys.RControlKey ||
                    parsed == Keys.LShiftKey || parsed == Keys.RShiftKey ||
                    parsed == Keys.LMenu || parsed == Keys.RMenu || mainKey != Keys.None)
                    throw new InvalidDataException("\u65e0\u6cd5\u8bc6\u522b\u6309\u952e\u201c" + part + "\u201d\uff1b\u8bf7\u4f7f\u7528 A\u3001F1\u3001Enter\u3001Space \u7b49\u6309\u952e\u540d\u79f0\u3002");
                mainKey = parsed;
            }

            if (mainKey == Keys.None)
                throw new InvalidDataException("\u7ec4\u5408\u952e\u5fc5\u987b\u5305\u542b\u4e00\u4e2a\u975e\u4fee\u9970\u952e\u3002");

            List<Keys> result = new List<Keys>(4);
            if (control)
                result.Add(Keys.ControlKey);
            if (alt)
                result.Add(Keys.Menu);
            if (shift)
                result.Add(Keys.ShiftKey);
            result.Add(mainKey);
            return result;
        }
    }

    public static class ManualProgramStore
    {
        private const int MaximumJsonBytes = 1024 * 1024;

        private static DataContractJsonSerializer CreateSerializer()
        {
            return new DataContractJsonSerializer(typeof(ManualProgram),
                new DataContractJsonSerializerSettings { MaxItemsInObjectGraph = 10000 });
        }

        public static ManualProgram Load(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("JSON \u6587\u4ef6\u8def\u5f84\u4e0d\u80fd\u4e3a\u7a7a\u3002", "path");
            FileInfo info = new FileInfo(path);
            if (!info.Exists)
                throw new FileNotFoundException("\u627e\u4e0d\u5230 JSON \u6d41\u7a0b\u6587\u4ef6\u3002", path);
            if (info.Length > MaximumJsonBytes)
                throw new InvalidDataException("JSON \u6d41\u7a0b\u6587\u4ef6\u4e0d\u80fd\u8d85\u8fc7 1 MB\u3002");

            ManualProgram program;
            using (FileStream stream = File.OpenRead(path))
                program = CreateSerializer().ReadObject(stream) as ManualProgram;
            ManualProgramValidator.Validate(program, false);
            return program;
        }

        public static void Save(string path, ManualProgram program)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("JSON \u6587\u4ef6\u8def\u5f84\u4e0d\u80fd\u4e3a\u7a7a\u3002", "path");
            ManualProgramValidator.Validate(program, false);
            byte[] bytes;
            using (MemoryStream stream = new MemoryStream())
            {
                CreateSerializer().WriteObject(stream, program);
                bytes = stream.ToArray();
            }
            if (bytes.Length > MaximumJsonBytes)
                throw new InvalidDataException("JSON \u6d41\u7a0b\u6587\u4ef6\u4e0d\u80fd\u8d85\u8fc7 1 MB\u3002");

            path = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporaryPath = null;
            try
            {
                for (int attempt = 0; attempt < 10 && temporaryPath == null; attempt++)
                {
                    string candidate = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    FileStream temporaryStream;
                    try
                    {
                        temporaryStream = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    }
                    catch (IOException)
                    {
                        if (File.Exists(candidate))
                            continue;
                        throw;
                    }

                    temporaryPath = candidate;
                    using (temporaryStream)
                        temporaryStream.Write(bytes, 0, bytes.Length);
                }
                if (temporaryPath == null)
                    throw new IOException("Could not create a unique temporary file for the JSON flow.");
                if (File.Exists(path))
                    File.Replace(temporaryPath, path, null);
                else
                    File.Move(temporaryPath, path);
                temporaryPath = null;
            }
            finally
            {
                if (temporaryPath != null && File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
        }
    }

    public static class ManualProgramRunner
    {
        private enum SignalKind { Completed, Cancelled, LoopTimeLimit }

        private sealed class LoopContext
        {
            public ManualBlock Block;
            public double StartedAt;
        }

        private sealed class RunSignal
        {
            public SignalKind Kind;
            public LoopContext Context;
        }

        private static readonly RunSignal Completed = new RunSignal { Kind = SignalKind.Completed };
        private static readonly RunSignal Cancelled = new RunSignal { Kind = SignalKind.Cancelled };

        public static bool Run(ManualProgram program, Func<string, Func<bool>, bool> sendText,
            Action<string> sendKey, Func<bool> cancellationRequested, Action<int> wait)
        {
            return Run(program, sendText, sendKey, cancellationRequested, wait,
                delegate { return (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency; });
        }

        public static bool Run(ManualProgram program, Func<string, Func<bool>, bool> sendText,
            Action<string> sendKey, Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            ManualProgramValidator.Validate(program, true);
            if (sendText == null || sendKey == null || cancellationRequested == null || wait == null || clock == null)
                throw new ArgumentNullException("Runner callbacks cannot be null.");

            List<LoopContext> loops = new List<LoopContext>();
            RunSignal signal = ExecuteBlocks(program.Blocks, loops, sendText, sendKey,
                cancellationRequested, wait, clock);
            return signal.Kind == SignalKind.Completed;
        }

        private static RunSignal ExecuteBlocks(List<ManualBlock> blocks, List<LoopContext> loops,
            Func<string, Func<bool>, bool> sendText, Action<string> sendKey,
            Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            for (int i = 0; i < blocks.Count; i++)
            {
                RunSignal signal = GetInterruption(loops, cancellationRequested, clock);
                if (signal.Kind != SignalKind.Completed)
                    return signal;

                ManualBlock block = blocks[i];
                if (block.Type == ManualBlock.Text)
                {
                    bool sent = sendText(block.Value, delegate
                    {
                        return GetInterruption(loops, cancellationRequested, clock).Kind != SignalKind.Completed;
                    });
                    if (!sent)
                        return GetInterruption(loops, cancellationRequested, clock).Kind == SignalKind.Completed ? Cancelled :
                            GetInterruption(loops, cancellationRequested, clock);
                }
                else if (block.Type == ManualBlock.Key)
                {
                    sendKey(block.Value);
                }
                else if (block.Type == ManualBlock.Wait)
                {
                    signal = WaitFor(block.Seconds, loops, cancellationRequested, wait, clock);
                    if (signal.Kind != SignalKind.Completed)
                        return signal;
                }
                else if (block.Type == ManualBlock.Loop)
                {
                    signal = ExecuteLoop(block, loops, sendText, sendKey, cancellationRequested, wait, clock);
                    if (signal.Kind != SignalKind.Completed)
                        return signal;
                }
            }
            return GetInterruption(loops, cancellationRequested, clock);
        }

        private static RunSignal ExecuteLoop(ManualBlock block, List<LoopContext> loops,
            Func<string, Func<bool>, bool> sendText, Action<string> sendKey,
            Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            LoopContext context = new LoopContext { Block = block, StartedAt = clock() };
            loops.Add(context);
            int iterations = 0;
            try
            {
                while (true)
                {
                    if (block.MaxIterations > 0 && iterations >= block.MaxIterations)
                        return Completed;

                    RunSignal signal = GetInterruption(loops, cancellationRequested, clock);
                    if (signal.Kind == SignalKind.Cancelled)
                        return signal;
                    if (signal.Kind == SignalKind.LoopTimeLimit)
                    {
                        if (signal.Context == context)
                            return Completed;
                        return signal;
                    }

                    iterations++;
                    signal = ExecuteBlocks(block.Children, loops, sendText, sendKey,
                        cancellationRequested, wait, clock);
                    if (signal.Kind == SignalKind.Cancelled)
                        return signal;
                    if (signal.Kind == SignalKind.LoopTimeLimit)
                    {
                        if (signal.Context == context)
                            return Completed;
                        return signal;
                    }
                }
            }
            finally
            {
                loops.RemoveAt(loops.Count - 1);
            }
        }

        private static RunSignal WaitFor(double seconds, List<LoopContext> loops,
            Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            double deadline = clock() + seconds;
            while (clock() < deadline)
            {
                RunSignal signal = GetInterruption(loops, cancellationRequested, clock);
                if (signal.Kind != SignalKind.Completed)
                    return signal;
                int milliseconds = (int)Math.Ceiling(Math.Min(25.0, (deadline - clock()) * 1000.0));
                wait(Math.Max(1, milliseconds));
            }
            return GetInterruption(loops, cancellationRequested, clock);
        }

        private static RunSignal GetInterruption(List<LoopContext> loops,
            Func<bool> cancellationRequested, Func<double> clock)
        {
            if (cancellationRequested())
                return Cancelled;
            double now = clock();
            for (int i = 0; i < loops.Count; i++)
            {
                LoopContext context = loops[i];
                double limit = context.Block.MaxDurationSeconds;
                if (limit > 0 && now - context.StartedAt >= limit)
                    return new RunSignal { Kind = SignalKind.LoopTimeLimit, Context = context };
            }
            return Completed;
        }
    }

    public static class ManualProgramTests
    {
        public static string RunSelfTests()
        {
            List<Keys> chord = ManualProgramValidator.ParseKeyChord("Ctrl+Shift+A");
            Assert(chord.Count == 3 && chord[0] == Keys.ControlKey && chord[1] == Keys.ShiftKey && chord[2] == Keys.A,
                "Key-chord parsing did not preserve modifier order.");
            Assert(ManualProgramValidator.ParseKeyChord("Enter")[0] == Keys.Enter,
                "The Enter key name was not recognized.");
            Assert(ManualProgramValidator.ParseKeyChord("Prior")[0] == Keys.PageUp &&
                ManualProgramValidator.ParseKeyChord("Next")[0] == Keys.PageDown,
                "The PageUp/PageDown aliases were not recognized.");
            string[] extendedKeyNames = new string[]
            {
                "PageUp", "PageDown", "Home", "End", "Insert", "Delete", "Left", "Right", "Up", "Down",
                "Snapshot", "PrintScreen", "LWin", "RWin", "Apps", "Divide", "NumLock"
            };
            for (int i = 0; i < extendedKeyNames.Length; i++)
            {
                List<Stroke> keyStrokes = KeyboardInput.BuildKeyChordStrokes(extendedKeyNames[i]);
                Assert(keyStrokes.Count == 2 && keyStrokes[0].VirtualKey == 0 &&
                    keyStrokes[0].ScanCode != 0 &&
                    (keyStrokes[0].Flags & KeyboardInput.KeyEventScanCode) != 0 &&
                    (keyStrokes[0].Flags & KeyboardInput.KeyEventExtended) != 0 &&
                    keyStrokes[1].VirtualKey == 0 && keyStrokes[1].ScanCode == keyStrokes[0].ScanCode &&
                    (keyStrokes[1].Flags & (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp)) ==
                        (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp),
                    "Scan-code extended-key events were not created for " + extendedKeyNames[i] +
                    " (vk=" + keyStrokes[0].VirtualKey + ", scan=" + keyStrokes[0].ScanCode +
                    ", flags=" + keyStrokes[0].Flags + ").");
            }
            List<Stroke> letterKey = KeyboardInput.BuildKeyChordStrokes("A");
            Assert(letterKey.Count == 2 && letterKey[0].VirtualKey == (ushort)Keys.A && letterKey[0].ScanCode == 0 &&
                letterKey[0].Flags == 0 && letterKey[1].VirtualKey == (ushort)Keys.A &&
                letterKey[1].Flags == KeyboardInput.KeyEventKeyUp,
                "A regular key no longer preserves its virtual-key down/up pair.");
            List<Stroke> combinedPageUp = KeyboardInput.BuildKeyChordStrokes("Ctrl+PageUp");
            Assert(combinedPageUp.Count == 4 && combinedPageUp[0].VirtualKey == (ushort)Keys.ControlKey &&
                combinedPageUp[0].Flags == 0 && combinedPageUp[1].VirtualKey == 0 &&
                combinedPageUp[1].ScanCode == 0x49 &&
                (combinedPageUp[1].Flags & (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended)) ==
                    (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended) &&
                (combinedPageUp[2].Flags & (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp)) ==
                    (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp) &&
                combinedPageUp[3].VirtualKey == (ushort)Keys.ControlKey &&
                combinedPageUp[3].Flags == KeyboardInput.KeyEventKeyUp,
                "Ctrl+PageUp did not produce the expected extended scan-code sequence.");
            bool invalidChordRejected = false;
            try
            {
                ManualProgramValidator.ParseKeyChord("Ctrl+");
            }
            catch (InvalidDataException)
            {
                invalidChordRejected = true;
            }
            Assert(invalidChordRejected, "Malformed key chords must be rejected.");

            ManualProgram original = new ManualProgram();
            ManualBlock loop = new ManualBlock
            {
                    Type = ManualBlock.Loop,
                    MaxIterations = 3,
                    Children = new List<ManualBlock>
                    {
                    new ManualBlock { Type = ManualBlock.Text, Value = "\u4f60\u597d\ud83d\ude00" },
                    new ManualBlock { Type = ManualBlock.Wait, Seconds = 0.25 }
                }
            };
            original.Blocks.Add(loop);
            string path = Path.Combine(Path.GetTempPath(), "SimulateKeyboardInput-flow-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                File.WriteAllText(path + ".tmp", "keep-existing-temporary-file");
                ManualProgramStore.Save(path, original);
                Assert(File.ReadAllText(path + ".tmp") == "keep-existing-temporary-file",
                    "Saving a flow changed an unrelated file using the old fixed temporary path.");
                ManualProgram loaded = ManualProgramStore.Load(path);
                Assert(loaded.Version == 1 && loaded.Blocks.Count == 1 && loaded.Blocks[0].Children.Count == 2 &&
                    loaded.Blocks[0].Children[0].Value == "\u4f60\u597d\ud83d\ude00" && loaded.Blocks[0].MaxIterations == 3,
                    "Manual program JSON did not round-trip its nested blocks.");
                original.Blocks[0].Children[0].Value = "updated";
                ManualProgramStore.Save(path, original);
                Assert(ManualProgramStore.Load(path).Blocks[0].Children[0].Value == "updated",
                    "Saving again did not replace the selected JSON file.");
                Assert(File.ReadAllText(path + ".tmp") == "keep-existing-temporary-file",
                    "Saving again changed an unrelated temporary-path file.");
            }
            finally
            {
                if (File.Exists(path))
                    File.Delete(path);
                if (File.Exists(path + ".tmp"))
                    File.Delete(path + ".tmp");
            }

            ManualProgram counted = new ManualProgram();
            counted.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxIterations = 3,
                Children = new List<ManualBlock> { new ManualBlock { Type = ManualBlock.Text, Value = "x" } }
            });
            int sentCount = 0;
            double fakeTime = 0;
            bool completed = ManualProgramRunner.Run(counted,
                delegate(string text, Func<bool> cancel) { sentCount++; return !cancel(); },
                delegate { }, delegate { return false; }, delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; },
                delegate { return fakeTime; });
            Assert(completed && sentCount == 3, "A count-limited loop did not run exactly the configured number of times.");

            ManualProgram timed = new ManualProgram();
            timed.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxDurationSeconds = 0.05,
                Children = new List<ManualBlock> { new ManualBlock { Type = ManualBlock.Wait, Seconds = 1 } }
            });
            fakeTime = 0;
            completed = ManualProgramRunner.Run(timed,
                delegate(string text, Func<bool> cancel) { return true; }, delegate { }, delegate { return false; },
                delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; }, delegate { return fakeTime; });
            Assert(completed && fakeTime >= 0.05 && fakeTime < 0.1,
                "A time-limited loop did not interrupt its wait at the configured limit.");

            ManualProgram nested = new ManualProgram();
            nested.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxIterations = 2,
                Children = new List<ManualBlock>
                {
                    new ManualBlock
                    {
                        Type = ManualBlock.Loop,
                        MaxDurationSeconds = 0.05,
                        Children = new List<ManualBlock> { new ManualBlock { Type = ManualBlock.Wait, Seconds = 1 } }
                    },
                    new ManualBlock { Type = ManualBlock.Text, Value = "outer" }
                }
            });
            fakeTime = 0;
            sentCount = 0;
            completed = ManualProgramRunner.Run(nested,
                delegate(string text, Func<bool> cancel) { sentCount++; return !cancel(); }, delegate { },
                delegate { return false; }, delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; },
                delegate { return fakeTime; });
            Assert(completed && sentCount == 2,
                "An inner loop time limit did not return control to the enclosing loop.");

            ManualProgram outerTimed = new ManualProgram();
            outerTimed.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxDurationSeconds = 0.05,
                Children = new List<ManualBlock>
                {
                    new ManualBlock
                    {
                        Type = ManualBlock.Loop,
                        MaxIterations = 10,
                        Children = new List<ManualBlock>
                        {
                            new ManualBlock { Type = ManualBlock.Wait, Seconds = 1 },
                            new ManualBlock { Type = ManualBlock.Text, Value = "inner" }
                        }
                    },
                    new ManualBlock { Type = ManualBlock.Text, Value = "outer" }
                }
            });
            outerTimed.Blocks.Add(new ManualBlock { Type = ManualBlock.Text, Value = "after" });
            fakeTime = 0;
            List<string> output = new List<string>();
            completed = ManualProgramRunner.Run(outerTimed,
                delegate(string text, Func<bool> cancel) { output.Add(text); return !cancel(); }, delegate { },
                delegate { return false; }, delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; },
                delegate { return fakeTime; });
            Assert(completed && output.Count == 1 && output[0] == "after",
                "An outer loop time limit did not interrupt a nested loop and continue after it.");

            ManualProgram cancelledProgram = new ManualProgram();
            cancelledProgram.Blocks.Add(new ManualBlock { Type = ManualBlock.Text, Value = "first" });
            cancelledProgram.Blocks.Add(new ManualBlock { Type = ManualBlock.Text, Value = "second" });
            sentCount = 0;
            completed = ManualProgramRunner.Run(cancelledProgram,
                delegate(string text, Func<bool> cancel) { sentCount++; return true; }, delegate { },
                delegate { return sentCount > 0; }, delegate(int milliseconds) { }, delegate { return 0; });
            Assert(!completed && sentCount == 1, "A cancellation request did not stop later blocks.");

            ManualProgramValidator.Validate(timed, true);
            KeyCaptureTextBox.RunCaptureSelfTests();
            using (ManualOperationPanel panel = new ManualOperationPanel())
            {
                panel.RunFooterLayoutSelfTest();
                panel.RunCaptureIntegrationSelfTest();
            }
            using (KeyboardForm form = new KeyboardForm())
            {
                Assert(form.Controls.Count == 2, "The shared header and source tabs were not initialized.");
                form.RunSharedChromeSelfTest();
                form.RunStatusRoutingSelfTest();
            }
            return "Self-test passed: nested JSON persistence, key-chord parsing, loop limits, cancellation, control-key capture/display, aligned status actions, shared page chrome, and page-specific status routing.";
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition)
                throw new InvalidOperationException(message);
        }
    }

    public sealed class KeyCaptureTextBox : TextBox
    {
        public KeyCaptureTextBox()
        {
            ReadOnly = true;
            BackColor = SystemColors.Window;
        }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            CaptureKey(keyData);
            return true;
        }

        protected override bool ProcessDialogKey(Keys keyData)
        {
            CaptureKey(keyData);
            return true;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            CaptureKey(e.KeyData);
            e.Handled = true;
            e.SuppressKeyPress = true;
            base.OnKeyDown(e);
        }

        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            e.Handled = true;
            base.OnKeyPress(e);
        }

        private void CaptureKey(Keys keyData)
        {
            Keys key = keyData & Keys.KeyCode;
            if (key == Keys.None || key == Keys.ControlKey || key == Keys.ShiftKey || key == Keys.Menu ||
                key == Keys.LControlKey || key == Keys.RControlKey ||
                key == Keys.LShiftKey || key == Keys.RShiftKey ||
                key == Keys.LMenu || key == Keys.RMenu)
                return;

            string name;
            switch (key)
            {
                case Keys.PageUp: name = "PageUp"; break;
                case Keys.PageDown: name = "PageDown"; break;
                case Keys.Enter: name = "Enter"; break;
                case Keys.Back: name = "Back"; break;
                case Keys.PrintScreen: name = "PrintScreen"; break;
                default: name = key.ToString(); break;
            }

            string chord = ((keyData & Keys.Control) != 0 ? "Ctrl+" : String.Empty) +
                ((keyData & Keys.Alt) != 0 ? "Alt+" : String.Empty) +
                ((keyData & Keys.Shift) != 0 ? "Shift+" : String.Empty) + name;
            try
            {
                ManualProgramValidator.ParseKeyChord(chord);
            }
            catch (InvalidDataException)
            {
                // Ignore unsupported key codes rather than storing an unrunnable block.
                return;
            }
            Text = chord;
            SelectionStart = Text.Length;
        }

        internal static void RunCaptureSelfTests()
        {
            using (KeyCaptureTextBox input = new KeyCaptureTextBox())
            {
                Keys[] keys = new Keys[]
                {
                    Keys.PageUp, Keys.PageDown, Keys.Left, Keys.Right, Keys.Up, Keys.Down,
                    Keys.Home, Keys.End, Keys.Insert, Keys.Delete, Keys.Tab, Keys.Enter,
                    Keys.Escape, Keys.Back, Keys.F1, Keys.A, Keys.Control | Keys.PageUp,
                    Keys.Control | Keys.Shift | Keys.A, Keys.Alt | Keys.F4
                };
                string[] names = new string[]
                {
                    "PageUp", "PageDown", "Left", "Right", "Up", "Down",
                    "Home", "End", "Insert", "Delete", "Tab", "Enter",
                    "Escape", "Back", "F1", "A", "Ctrl+PageUp", "Ctrl+Shift+A", "Alt+F4"
                };
                for (int i = 0; i < keys.Length; i++)
                {
                    Message message = Message.Create(IntPtr.Zero, 0x0100, IntPtr.Zero, IntPtr.Zero);
                    if (!input.ProcessCmdKey(ref message, keys[i]) || input.Text != names[i])
                        throw new InvalidOperationException("Command-key capture failed for " + names[i] + ".");
                    ManualProgramValidator.ParseKeyChord(input.Text);
                }
                input.Text = "PageUp";
                input.ProcessDialogKey(Keys.Tab);
                if (input.Text != "Tab")
                    throw new InvalidOperationException("Dialog-key capture failed for Tab.");
                KeyEventArgs down = new KeyEventArgs(Keys.Control | Keys.PageUp);
                input.OnKeyDown(down);
                if (input.Text != "Ctrl+PageUp" || !down.Handled || !down.SuppressKeyPress)
                    throw new InvalidOperationException("KeyDown capture did not suppress the original key.");
                input.OnKeyDown(new KeyEventArgs(Keys.Control | Keys.ControlKey));
                if (input.Text != "Ctrl+PageUp")
                    throw new InvalidOperationException("A modifier-only press replaced the recorded chord.");
                KeyPressEventArgs character = new KeyPressEventArgs('x');
                input.OnKeyPress(character);
                if (!character.Handled || input.Text != "Ctrl+PageUp")
                    throw new InvalidOperationException("Captured keys leaked into ordinary text entry.");

                // Exercise WinForms preprocessing and window dispatch locally, without SendInput.
                Keys[] routedKeys = new Keys[] { Keys.PageUp, Keys.PageDown, Keys.Left, Keys.Tab, Keys.Enter, Keys.Escape };
                string[] routedNames = new string[] { "PageUp", "PageDown", "Left", "Tab", "Enter", "Escape" };
                for (int i = 0; i < routedKeys.Length; i++)
                {
                    Message message = Message.Create(input.Handle, 0x0100, new IntPtr((int)routedKeys[i]), IntPtr.Zero);
                    if (!input.PreProcessMessage(ref message))
                        input.WndProc(ref message);
                    if (input.Text != routedNames[i])
                        throw new InvalidOperationException("WinForms message routing failed for " + routedNames[i] + ".");
                }
            }
        }
    }

    public static class UiChrome
    {
        public static Panel CreatePageHeading(string title, string description)
        {
            Panel heading = new Panel();
            heading.Dock = DockStyle.Top;
            heading.Height = 58;
            heading.BackColor = SystemColors.Control;

            Label titleLabel = new Label();
            titleLabel.AutoSize = true;
            titleLabel.Location = new Point(18, 7);
            titleLabel.Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 12.0F, FontStyle.Bold);
            titleLabel.Text = title;

            Label descriptionLabel = new Label();
            descriptionLabel.AutoSize = true;
            descriptionLabel.Location = new Point(18, 34);
            descriptionLabel.ForeColor = SystemColors.GrayText;
            descriptionLabel.Text = description;

            heading.Controls.Add(titleLabel);
            heading.Controls.Add(descriptionLabel);
            return heading;
        }
    }

    public sealed class ManualOperationPanel : UserControl
    {
        private readonly TreeView _tree;
        private readonly Panel _propertiesPanel;
        private readonly Label _statusLabel;
        private readonly Button _stopButton;
        private readonly Label _selectionLabel;
        private readonly TableLayoutPanel _footer;
        private string _currentPath;
        private bool _dirty;
        private bool _loadingProperties;

        public event EventHandler StopRequested;

        public ManualOperationPanel()
        {
            Dock = DockStyle.Fill;
            BackColor = SystemColors.Control;

            FlowLayoutPanel toolbar = new FlowLayoutPanel();
            toolbar.Dock = DockStyle.Top;
            toolbar.Height = 58;
            toolbar.Padding = new Padding(12, 10, 12, 8);
            toolbar.WrapContents = true;
            toolbar.AutoSize = false;
            toolbar.BackColor = SystemColors.Control;

            AddToolbarButton(toolbar, "\u65b0\u5efa", NewProgram);
            AddToolbarButton(toolbar, "\u6253\u5f00 JSON", OpenProgram);
            AddToolbarButton(toolbar, "\u4fdd\u5b58", SaveProgramClick);
            AddToolbarButton(toolbar, "\u53e6\u5b58\u4e3a", SaveAsProgramClick);
            AddToolbarButton(toolbar, "+ \u8f93\u5165", delegate { AddBlock(ManualBlock.Text); });
            AddToolbarButton(toolbar, "+ \u7b49\u5f85", delegate { AddBlock(ManualBlock.Wait); });
            AddToolbarButton(toolbar, "+ \u5faa\u73af", delegate { AddBlock(ManualBlock.Loop); });
            AddToolbarButton(toolbar, "\u5220\u9664", DeleteSelectedBlock);

            SplitContainer split = new SplitContainer();
            split.Dock = DockStyle.Fill;
            split.Orientation = Orientation.Vertical;
            split.Size = new Size(900, 400);
            split.Panel1MinSize = 280;
            split.Panel2MinSize = 280;
            split.SplitterDistance = 570;

            _tree = new TreeView();
            _tree.Dock = DockStyle.Fill;
            _tree.HideSelection = false;
            _tree.AllowDrop = true;
            _tree.ShowLines = true;
            _tree.ShowPlusMinus = true;
            _tree.ShowRootLines = true;
            _tree.AfterSelect += delegate { RenderProperties(); };
            _tree.ItemDrag += TreeItemDrag;
            _tree.DragEnter += TreeDragEnter;
            _tree.DragOver += TreeDragOver;
            _tree.DragDrop += TreeDragDrop;
            split.Panel1.Controls.Add(_tree);

            _propertiesPanel = new Panel();
            _propertiesPanel.Dock = DockStyle.Fill;
            _propertiesPanel.AutoScroll = true;
            split.Panel2.Controls.Add(_propertiesPanel);

            _selectionLabel = new Label();
            _selectionLabel.Dock = DockStyle.Top;
            _selectionLabel.Height = 30;
            _selectionLabel.Padding = new Padding(10, 8, 0, 0);
            _selectionLabel.Font = new Font(Font, FontStyle.Bold);
            _selectionLabel.Text = "\u8f93\u5165\u79ef\u6728";
            split.Panel2.Controls.Add(_selectionLabel);

            _footer = new TableLayoutPanel();
            _footer.Dock = DockStyle.Bottom;
            _footer.Height = 48;
            _footer.ColumnCount = 2;
            _footer.RowCount = 1;
            _footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            _footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            _footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            _footer.Padding = new Padding(12, 0, 12, 0);
            _footer.BorderStyle = BorderStyle.FixedSingle;
            _footer.BackColor = SystemColors.Control;

            _statusLabel = new Label();
            _statusLabel.Dock = DockStyle.Fill;
            _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            _statusLabel.AutoEllipsis = true;
            _statusLabel.Text = "\u5df2\u51c6\u5907\u5c31\u7eea\u3002\u9009\u62e9\u6d41\u7a0b\u79ef\u6728\u4ee5\u4fee\u6539\u53c2\u6570\u3002";

            _stopButton = new Button();
            _stopButton.Text = "\u505c\u6b62\u8fd0\u884c";
            _stopButton.Size = new Size(105, 30);
            _stopButton.Anchor = AnchorStyles.None;
            _stopButton.Margin = new Padding(10, 0, 0, 0);
            _stopButton.Enabled = false;
            _stopButton.Click += delegate
            {
                EventHandler handler = StopRequested;
                if (handler != null)
                    handler(this, EventArgs.Empty);
            };
            _footer.Controls.Add(_statusLabel, 0, 0);
            _footer.Controls.Add(_stopButton, 1, 0);

            Controls.Add(split);
            Controls.Add(_footer);
            Controls.Add(toolbar);
            Controls.Add(UiChrome.CreatePageHeading("\u624b\u52a8\u64cd\u4f5c\u79ef\u6728",
                "\u6309\u987a\u5e8f\u7ec4\u5408\u6587\u672c\u3001\u6309\u952e\u3001\u7b49\u5f85\u548c\u5faa\u73af\u3002"));

            RenderProperties();
        }

        public void SetStatusText(string message)
        {
            _statusLabel.Text = message ?? String.Empty;
        }

        internal string GetStatusTextForSelfTest()
        {
            return _statusLabel.Text;
        }

        internal void RunFooterLayoutSelfTest()
        {
            _footer.PerformLayout();
            int buttonCenter = _stopButton.Top + _stopButton.Height / 2;
            if (_statusLabel.Dock != DockStyle.Fill ||
                _statusLabel.TextAlign != ContentAlignment.MiddleLeft ||
                Math.Abs(buttonCenter - _footer.ClientSize.Height / 2) > 2)
                throw new InvalidOperationException("The manual-page status and stop action are not vertically aligned.");
        }

        public ManualProgram GetProgram()
        {
            ManualProgram program = new ManualProgram();
            program.Blocks = ReadBlocks(_tree.Nodes);
            return program;
        }

        internal void RunCaptureIntegrationSelfTest()
        {
            AddBlock(ManualBlock.Text);
            ComboBox mode = null;
            foreach (Control control in _propertiesPanel.Controls)
            {
                if (control is ComboBox)
                    mode = (ComboBox)control;
            }
            if (mode == null)
                throw new InvalidOperationException("The input-mode selector was not created.");
            mode.SelectedIndex = 1;
            KeyCaptureTextBox capture = null;
            foreach (Control control in _propertiesPanel.Controls)
            {
                if (control is KeyCaptureTextBox)
                    capture = (KeyCaptureTextBox)control;
            }
            if (capture == null)
                throw new InvalidOperationException("Key mode is not connected to a capture textbox.");
            _dirty = false;
            Message message = Message.Create(capture.Handle, 0x0100, new IntPtr((int)Keys.PageUp), IntPtr.Zero);
            // PageUp is a command key; WinForms must consume it before scrolling/focus handling.
            if (!capture.PreProcessMessage(ref message))
                throw new InvalidOperationException("PageUp was not intercepted by the capture control.");
            ManualProgram program = GetProgram();
            if (capture.Text != "PageUp" || program.Blocks[0].Type != ManualBlock.Key ||
                program.Blocks[0].Value != "PageUp" || !_dirty ||
                !_tree.SelectedNode.Text.Contains("PageUp"))
                throw new InvalidOperationException("Captured PageUp was not reflected in the block label/model.");

            string path = Path.Combine(Path.GetTempPath(), "SimulateKeyboardInput-capture-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                ManualProgramStore.Save(path, program);
                LoadProgram(ManualProgramStore.Load(path));
                _tree.SelectedNode = _tree.Nodes[0];
                if (!_tree.Nodes[0].Text.Contains("PageUp") || GetProgram().Blocks[0].Value != "PageUp")
                    throw new InvalidOperationException("Captured key names did not survive JSON reload.");
            }
            finally
            {
                if (File.Exists(path))
                    File.Delete(path);
            }

            foreach (Control control in _propertiesPanel.Controls)
            {
                if (control is ComboBox)
                    mode = (ComboBox)control;
            }
            mode.SelectedIndex = 0;
            foreach (Control control in _propertiesPanel.Controls)
            {
                TextBox text = control as TextBox;
                if (text == null)
                    continue;
                if (text is KeyCaptureTextBox || text.ReadOnly || !text.Multiline)
                    throw new InvalidOperationException("Text mode retained key capture instead of normal editing.");
                text.Text = "normal text";
            }
            if (GetProgram().Blocks[0].Type != ManualBlock.Text || GetProgram().Blocks[0].Value != "normal text")
                throw new InvalidOperationException("Normal text editing was not preserved.");
            _dirty = false;
        }

        public void SetRunState(bool running, string message)
        {
            _stopButton.Enabled = running;
            _statusLabel.Text = message;
        }

        public bool ConfirmClose()
        {
            if (!_dirty)
                return true;
            DialogResult result = MessageBox.Show(this,
                "\u5f53\u524d\u6d41\u7a0b\u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539\uff0c\u662f\u5426\u4fdd\u5b58\uff1f",
                "\u64cd\u4f5c\u6d41\u7a0b", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (result == DialogResult.Yes)
                return SaveProgram();
            return result == DialogResult.No;
        }

        private static void AddToolbarButton(FlowLayoutPanel toolbar, string text, EventHandler handler)
        {
            Button button = new Button();
            button.Text = text;
            button.AutoSize = true;
            button.Height = 30;
            button.Margin = new Padding(3);
            button.Click += handler;
            toolbar.Controls.Add(button);
        }

        private void NewProgram(object sender, EventArgs e)
        {
            if (!ConfirmReplace())
                return;
            _tree.Nodes.Clear();
            _currentPath = null;
            _dirty = false;
            SetStatus("\u65b0\u5efa\u6d41\u7a0b\u5df2\u5c31\u7eea\u3002");
            RenderProperties();
        }

        private void OpenProgram(object sender, EventArgs e)
        {
            if (!ConfirmReplace())
                return;
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "\u6253\u5f00 JSON \u6d41\u7a0b";
                dialog.Filter = "JSON \u6d41\u7a0b\u6587\u4ef6 (*.json)|*.json|\u6240\u6709\u6587\u4ef6 (*.*)|*.*";
                dialog.Multiselect = false;
                dialog.CheckFileExists = true;
                if (dialog.ShowDialog(this) != DialogResult.OK)
                    return;
                try
                {
                    ManualProgram program = ManualProgramStore.Load(dialog.FileName);
                    LoadProgram(program);
                    _currentPath = dialog.FileName;
                    _dirty = false;
                    SetStatus("\u64cd\u4f5c\u6d41\u7a0b\u5df2\u6253\u5f00\u3002");
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, ex.Message, "\u8bfb\u53d6\u5931\u8d25", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void SaveProgramClick(object sender, EventArgs e)
        {
            SaveProgram();
        }

        private void SaveAsProgramClick(object sender, EventArgs e)
        {
            SaveAsProgram();
        }

        private bool SaveProgram()
        {
            if (String.IsNullOrEmpty(_currentPath))
                return SaveAsProgram();
            try
            {
                ManualProgramStore.Save(_currentPath, GetProgram());
                _dirty = false;
                SetStatus("\u64cd\u4f5c\u6d41\u7a0b\u5df2\u4fdd\u5b58\u3002");
                return true;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "\u4fdd\u5b58\u5931\u8d25", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        private bool SaveAsProgram()
        {
            using (SaveFileDialog dialog = new SaveFileDialog())
            {
                dialog.Title = "\u4fdd\u5b58 JSON \u6d41\u7a0b";
                dialog.Filter = "JSON \u6d41\u7a0b\u6587\u4ef6 (*.json)|*.json|\u6240\u6709\u6587\u4ef6 (*.*)|*.*";
                dialog.DefaultExt = "json";
                dialog.AddExtension = true;
                dialog.OverwritePrompt = true;
                if (!String.IsNullOrEmpty(_currentPath))
                {
                    dialog.InitialDirectory = Path.GetDirectoryName(_currentPath);
                    dialog.FileName = Path.GetFileName(_currentPath);
                }
                if (dialog.ShowDialog(this) != DialogResult.OK)
                    return false;
                try
                {
                    ManualProgramStore.Save(dialog.FileName, GetProgram());
                    _currentPath = dialog.FileName;
                    _dirty = false;
                    SetStatus("\u64cd\u4f5c\u6d41\u7a0b\u5df2\u4fdd\u5b58\u3002");
                    return true;
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, ex.Message, "\u4fdd\u5b58\u5931\u8d25", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return false;
                }
            }
        }

        private bool ConfirmReplace()
        {
            if (!_dirty)
                return true;
            DialogResult result = MessageBox.Show(this,
                "\u5f53\u524d\u6d41\u7a0b\u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539\uff0c\u662f\u5426\u4fdd\u5b58\uff1f",
                "\u64cd\u4f5c\u6d41\u7a0b", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (result == DialogResult.Yes)
                return SaveProgram();
            return result == DialogResult.No;
        }

        private void AddBlock(string type)
        {
            ManualBlock block = new ManualBlock { Type = type };
            if (type == ManualBlock.Wait)
                block.Seconds = 1;
            else if (type == ManualBlock.Loop)
                block.MaxIterations = 1;
            else if (type == ManualBlock.Key)
                block.Value = "Enter";
            else
                block.Value = String.Empty;

            TreeNode node = CreateNode(block);
            TreeNode selected = _tree.SelectedNode;
            TreeNodeCollection destination;
            int index;
            if (selected == null)
            {
                destination = _tree.Nodes;
                index = destination.Count;
            }
            else if (((ManualBlock)selected.Tag).Type == ManualBlock.Loop)
            {
                destination = selected.Nodes;
                index = destination.Count;
                selected.Expand();
            }
            else
            {
                destination = selected.Parent == null ? _tree.Nodes : selected.Parent.Nodes;
                index = selected.Index + 1;
            }
            destination.Insert(index, node);
            _tree.SelectedNode = node;
            node.EnsureVisible();
            MarkDirty();
        }

        private void DeleteSelectedBlock(object sender, EventArgs e)
        {
            if (_tree.SelectedNode == null)
                return;
            TreeNode node = _tree.SelectedNode;
            TreeNode next = node.NextNode ?? node.PrevNode ?? node.Parent;
            node.Remove();
            _tree.SelectedNode = next;
            MarkDirty();
        }

        private void TreeItemDrag(object sender, ItemDragEventArgs e)
        {
            TreeNode node = e.Item as TreeNode;
            if (node != null)
                DoDragDrop(node, DragDropEffects.Move);
        }

        private void TreeDragEnter(object sender, DragEventArgs e)
        {
            e.Effect = e.Data.GetDataPresent(typeof(TreeNode)) ? DragDropEffects.Move : DragDropEffects.None;
        }

        private void TreeDragOver(object sender, DragEventArgs e)
        {
            TreeNode source = e.Data.GetData(typeof(TreeNode)) as TreeNode;
            TreeNode target = _tree.GetNodeAt(_tree.PointToClient(new Point(e.X, e.Y)));
            e.Effect = source != null && (target == null || (target != source && !IsDescendant(source, target))) ?
                DragDropEffects.Move : DragDropEffects.None;
        }

        private void TreeDragDrop(object sender, DragEventArgs e)
        {
            TreeNode source = e.Data.GetData(typeof(TreeNode)) as TreeNode;
            TreeNode target = _tree.GetNodeAt(_tree.PointToClient(new Point(e.X, e.Y)));
            if (source == null || target == source || (target != null && IsDescendant(source, target)))
                return;

            TreeNodeCollection destination;
            bool append;
            if (target == null)
            {
                destination = _tree.Nodes;
                append = true;
            }
            else if (((ManualBlock)target.Tag).Type == ManualBlock.Loop)
            {
                destination = target.Nodes;
                append = true;
                target.Expand();
            }
            else
            {
                destination = target.Parent == null ? _tree.Nodes : target.Parent.Nodes;
                append = false;
            }

            source.Remove();
            int index = append ? destination.Count : target.Index + 1;
            destination.Insert(index, source);
            _tree.SelectedNode = source;
            MarkDirty();
        }

        private static bool IsDescendant(TreeNode node, TreeNode possibleAncestor)
        {
            TreeNode current = node.Parent;
            while (current != null)
            {
                if (current == possibleAncestor)
                    return true;
                current = current.Parent;
            }
            return false;
        }

        private TreeNode CreateNode(ManualBlock block)
        {
            TreeNode node = new TreeNode(FormatBlock(block));
            node.Tag = block;
            if (block.Type == ManualBlock.Loop)
                node.BackColor = Color.FromArgb(255, 239, 205);
            else if (block.Type == ManualBlock.Wait)
                node.BackColor = Color.FromArgb(220, 237, 255);
            else if (block.Type == ManualBlock.Key)
                node.BackColor = Color.FromArgb(235, 225, 255);
            else
                node.BackColor = Color.FromArgb(221, 244, 225);
            if (block.Type == ManualBlock.Loop && block.Children != null)
            {
                for (int i = 0; i < block.Children.Count; i++)
                    node.Nodes.Add(CreateNode(block.Children[i]));
            }
            return node;
        }

        private static string FormatBlock(ManualBlock block)
        {
            if (block.Type == ManualBlock.Text)
            {
                string value = (block.Value ?? String.Empty).Replace("\r", " ").Replace("\n", " ");
                if (value.Length > 32)
                    value = value.Substring(0, 32) + "...";
                return "\u8f93\u5165\u6587\u672c\uff1a\u300c" + value + "\u300d";
            }
            if (block.Type == ManualBlock.Key)
                return "\u6309\u952e\uff1a\u300c" + (block.Value ?? String.Empty) + "\u300d";
            if (block.Type == ManualBlock.Wait)
                return "\u7b49\u5f85\uff1a" + block.Seconds.ToString("0.##", CultureInfo.CurrentCulture) + " \u79d2";
            string count = block.MaxIterations == 0 ? "\u4e0d\u9650" :
                block.MaxIterations.ToString(CultureInfo.CurrentCulture) + " \u6b21";
            string duration = block.MaxDurationSeconds == 0 ? "\u4e0d\u9650" :
                block.MaxDurationSeconds.ToString("0.##", CultureInfo.CurrentCulture) + " \u79d2";
            return "\u5faa\u73af\uff1a" + count + " / \u6700\u957f " + duration;
        }

        private void LoadProgram(ManualProgram program)
        {
            _tree.BeginUpdate();
            try
            {
                _tree.Nodes.Clear();
                for (int i = 0; i < program.Blocks.Count; i++)
                    _tree.Nodes.Add(CreateNode(program.Blocks[i]));
            }
            finally
            {
                _tree.EndUpdate();
            }
            RenderProperties();
        }

        private static List<ManualBlock> ReadBlocks(TreeNodeCollection nodes)
        {
            List<ManualBlock> blocks = new List<ManualBlock>();
            for (int i = 0; i < nodes.Count; i++)
            {
                ManualBlock source = (ManualBlock)nodes[i].Tag;
                ManualBlock block = new ManualBlock
                {
                    Type = source.Type,
                    Value = source.Value,
                    Seconds = source.Seconds,
                    MaxIterations = source.MaxIterations,
                    MaxDurationSeconds = source.MaxDurationSeconds,
                    Children = ReadBlocks(nodes[i].Nodes)
                };
                blocks.Add(block);
            }
            return blocks;
        }

        private void RenderProperties()
        {
            _propertiesPanel.Controls.Clear();
            TreeNode node = _tree.SelectedNode;
            if (node == null)
            {
                _selectionLabel.Text = "\u8f93\u5165\u79ef\u6728";
                Label empty = new Label();
                empty.Text = "\u5148\u9009\u62e9\u4e00\u4e2a\u79ef\u6728\u4fee\u6539\u53c2\u6570\u3002";
                empty.Location = new Point(16, 18);
                empty.AutoSize = true;
                _propertiesPanel.Controls.Add(empty);
                return;
            }

            ManualBlock block = (ManualBlock)node.Tag;
            _loadingProperties = true;
            try
            {
                if (block.Type == ManualBlock.Text || block.Type == ManualBlock.Key)
                {
                    _selectionLabel.Text = block.Type == ManualBlock.Text ? "\u8f93\u5165\u79ef\u6728" : "\u6309\u952e\u79ef\u6728";
                    AddPropertyLabel("\u8f93\u5165\u65b9\u5f0f", 15);
                    ComboBox mode = new ComboBox();
                    mode.DropDownStyle = ComboBoxStyle.DropDownList;
                    mode.Items.Add("\u6587\u672c");
                    mode.Items.Add("\u6309\u952e/\u7ec4\u5408\u952e");
                    mode.SelectedIndex = block.Type == ManualBlock.Text ? 0 : 1;
                    mode.Location = new Point(16, 38);
                    mode.Width = Math.Max(180, _propertiesPanel.ClientSize.Width - 42);
                    mode.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
                    _propertiesPanel.Controls.Add(mode);

                    AddPropertyLabel("\u8f93\u5165\u5185\u5bb9", 78);
                    TextBox value = block.Type == ManualBlock.Key ? (TextBox)new KeyCaptureTextBox() : new TextBox();
                    value.Text = block.Value ?? String.Empty;
                    value.MaxLength = block.Type == ManualBlock.Text ? 100000 : 100;
                    value.Location = new Point(16, 101);
                    value.Width = Math.Max(180, _propertiesPanel.ClientSize.Width - 42);
                    value.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
                    value.Multiline = block.Type == ManualBlock.Text;
                    value.Height = value.Multiline ? 150 : 24;
                    value.ScrollBars = value.Multiline ? ScrollBars.Vertical : ScrollBars.None;
                    _propertiesPanel.Controls.Add(value);

                    mode.SelectedIndexChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.Type = mode.SelectedIndex == 0 ? ManualBlock.Text : ManualBlock.Key;
                        UpdateNode(node, block);
                        MarkDirty();
                        RenderProperties();
                    };
                    value.TextChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.Value = value.Text;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                    if (block.Type == ManualBlock.Key)
                    {
                        Label hint = new Label();
                        hint.Text = "\u70b9\u51fb\u6846\u540e\u76f4\u63a5\u6309\u952e\uff08\u5982 PageUp\uff09";
                        hint.Location = new Point(16, 133);
                        hint.AutoSize = true;
                        _propertiesPanel.Controls.Add(hint);
                    }
                }
                else if (block.Type == ManualBlock.Wait)
                {
                    _selectionLabel.Text = "\u7b49\u5f85\u79ef\u6728";
                    AddPropertyLabel("\u7b49\u5f85\u65f6\u95f4\uff08\u79d2\uff09", 15);
                    NumericUpDown seconds = new NumericUpDown();
                    seconds.DecimalPlaces = 2;
                    seconds.Minimum = 0.01M;
                    seconds.Maximum = 3600M;
                    seconds.Increment = 0.1M;
                    seconds.Value = (decimal)block.Seconds;
                    seconds.Location = new Point(16, 39);
                    seconds.Width = 150;
                    seconds.ValueChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.Seconds = (double)seconds.Value;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                    _propertiesPanel.Controls.Add(seconds);
                }
                else
                {
                    _selectionLabel.Text = "\u5faa\u73af\u79ef\u6728";
                    AddPropertyLabel("\u5faa\u73af\u6b21\u6570\u4e0a\u9650", 15);
                    NumericUpDown iterations = new NumericUpDown();
                    iterations.Minimum = 0;
                    iterations.Maximum = 1000000;
                    iterations.Value = block.MaxIterations;
                    iterations.Location = new Point(16, 39);
                    iterations.Width = 150;
                    _propertiesPanel.Controls.Add(iterations);
                    AddPropertyLabel("0 \u8868\u793a\u4e0d\u9650", 65);
                    AddPropertyLabel("\u6700\u957f\u8fd0\u884c\u65f6\u95f4\uff08\u79d2\uff09", 95);
                    NumericUpDown duration = new NumericUpDown();
                    duration.DecimalPlaces = 2;
                    duration.Minimum = 0;
                    duration.Maximum = 86400;
                    duration.Increment = 1;
                    duration.Value = (decimal)block.MaxDurationSeconds;
                    duration.Location = new Point(16, 119);
                    duration.Width = 150;
                    _propertiesPanel.Controls.Add(duration);
                    AddPropertyLabel("0 \u8868\u793a\u4e0d\u9650", 145);
                    AddPropertyLabel("\u6b21\u6570\u6216\u8fd0\u884c\u65f6\u95f4\u81f3\u5c11\u8bbe\u7f6e\u4e00\u9879\uff1b\u8fbe\u5230\u4efb\u4e00\u4e0a\u9650\u5373\u9000\u51fa\u3002", 178);

                    iterations.ValueChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.MaxIterations = (int)iterations.Value;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                    duration.ValueChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.MaxDurationSeconds = (double)duration.Value;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                }
            }
            finally
            {
                _loadingProperties = false;
            }
        }

        private void AddPropertyLabel(string text, int top)
        {
            Label label = new Label();
            label.Text = text;
            label.Location = new Point(16, top);
            label.AutoSize = true;
            _propertiesPanel.Controls.Add(label);
        }

        private void UpdateNode(TreeNode node, ManualBlock block)
        {
            node.Text = FormatBlock(block);
            node.BackColor = block.Type == ManualBlock.Loop ? Color.FromArgb(255, 239, 205) :
                block.Type == ManualBlock.Wait ? Color.FromArgb(220, 237, 255) :
                block.Type == ManualBlock.Key ? Color.FromArgb(235, 225, 255) : Color.FromArgb(221, 244, 225);
        }

        private void MarkDirty()
        {
            _dirty = true;
            SetStatus("\u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539\u3002");
        }

        private void SetStatus(string text)
        {
            _statusLabel.Text = text;
        }
    }

    public sealed class ShortcutDialog : Form
    {
        private readonly TextBox _captureBox;
        private readonly Label _messageLabel;
        private readonly Button _saveButton;

        public ShortcutConfiguration SelectedShortcut { get; private set; }

        public ShortcutDialog(ShortcutConfiguration current)
        {
            Text = "\u4fee\u6539\u5feb\u6377\u952e";
            ClientSize = new Size(430, 190);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            KeyPreview = true;

            Label instruction = new Label();
            instruction.AutoSize = false;
            instruction.Location = new Point(20, 18);
            instruction.Size = new Size(390, 32);
            instruction.Text = "\u8bf7\u6309\u4e0b\u65b0\u7684\u5feb\u6377\u952e\u7ec4\u5408\uff08\u81f3\u5c11\u5305\u542b Ctrl\u3001Alt \u6216 Shift\uff09";

            _captureBox = new TextBox();
            _captureBox.ReadOnly = true;
            _captureBox.Location = new Point(20, 57);
            _captureBox.Size = new Size(390, 24);
            _captureBox.BackColor = SystemColors.Window;
            _captureBox.Text = current.DisplayText();

            _messageLabel = new Label();
            _messageLabel.AutoSize = false;
            _messageLabel.Location = new Point(20, 92);
            _messageLabel.Size = new Size(390, 30);
            _messageLabel.Text = "\u7b49\u5f85\u6309\u952e\u2026";

            _saveButton = new Button();
            _saveButton.Text = "\u4fdd\u5b58";
            _saveButton.Location = new Point(240, 140);
            _saveButton.Size = new Size(80, 28);
            _saveButton.Enabled = false;
            _saveButton.Click += delegate
            {
                if (SelectedShortcut != null)
                {
                    DialogResult = DialogResult.OK;
                    Close();
                }
            };

            Button cancelButton = new Button();
            cancelButton.Text = "\u53d6\u6d88";
            cancelButton.Location = new Point(330, 140);
            cancelButton.Size = new Size(80, 28);
            cancelButton.DialogResult = DialogResult.Cancel;

            Controls.Add(instruction);
            Controls.Add(_captureBox);
            Controls.Add(_messageLabel);
            Controls.Add(_saveButton);
            Controls.Add(cancelButton);
            CancelButton = cancelButton;
            Shown += delegate { _captureBox.Focus(); };
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                DialogResult = DialogResult.Cancel;
                Close();
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }

            if (IsModifierKey(e.KeyCode))
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }

            uint modifiers = 0;
            if (e.Control)
                modifiers |= ShortcutConfiguration.ModifierControl;
            if (e.Alt)
                modifiers |= ShortcutConfiguration.ModifierAlt;
            if (e.Shift)
                modifiers |= ShortcutConfiguration.ModifierShift;

            if (modifiers == 0)
            {
                _messageLabel.Text = "\u8bf7\u81f3\u5c11\u4f7f\u7528 Ctrl\u3001Alt \u6216 Shift \u4e2d\u7684\u4e00\u4e2a\u4fee\u9970\u952e\u3002";
            }
            else
            {
                SelectedShortcut = new ShortcutConfiguration(modifiers, (uint)e.KeyCode);
                _captureBox.Text = SelectedShortcut.DisplayText();
                _messageLabel.Text = "\u6309\u201c\u4fdd\u5b58\u201d\u4f7f\u7528\u8be5\u5feb\u6377\u952e\u3002";
                _saveButton.Enabled = true;
            }

            e.Handled = true;
            e.SuppressKeyPress = true;
        }

        private static bool IsModifierKey(Keys key)
        {
            return key == Keys.ControlKey || key == Keys.ShiftKey || key == Keys.Menu ||
                key == Keys.LControlKey || key == Keys.RControlKey ||
                key == Keys.LShiftKey || key == Keys.RShiftKey ||
                key == Keys.LMenu || key == Keys.RMenu;
        }
    }

    public sealed class KeyboardForm : Form
    {
        private const int HotkeyId = 0x534B;
        private const int WmHotkey = 0x0312;
        private const uint ModNoRepeat = 0x4000;
        private const int VkControl = 0x11;
        private const int VkMenu = 0x12;
        private const int VkShift = 0x10;

        private readonly TextBox _pathBox;
        private readonly FlowLayoutPanel _shortcutBar;
        private readonly Label _hotkeyValueLabel;
        private readonly Button _changeShortcutButton;
        private readonly Label _statusLabel;
        private readonly CheckBox _intervalCheckBox;
        private readonly NumericUpDown _intervalMillisecondsInput;
        private readonly TabControl _sourceTabs;
        private readonly TabPage _manualTab;
        private readonly ManualOperationPanel _manualPanel;
        private string _selectedPath;
        private ShortcutConfiguration _shortcut;
        private bool _hotkeyRegistered;
        private bool _isSending;
        private bool _manualRunning;
        private volatile bool _cancelSending;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr windowHandle, int id);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        public KeyboardForm()
        {
            _shortcut = ShortcutConfiguration.Load();
            Text = "\u6587\u4ef6\u8f6c\u952e\u76d8\u8f93\u5165";
            ClientSize = new Size(1040, 700);
            MinimumSize = new Size(900, 600);
            FormBorderStyle = FormBorderStyle.Sizable;
            MaximizeBox = true;
            StartPosition = FormStartPosition.CenterScreen;

            _sourceTabs = new TabControl();
            _sourceTabs.Dock = DockStyle.Fill;
            TabPage filePage = new TabPage("\u6587\u672c\u6587\u4ef6\u8f93\u5165");
            filePage.Size = new Size(1000, 650);
            filePage.BackColor = SystemColors.Control;
            filePage.Padding = new Padding(12);
            _manualTab = new TabPage("\u624b\u52a8\u64cd\u4f5c\u79ef\u6728");
            _manualTab.BackColor = SystemColors.Control;
            _manualTab.Padding = new Padding(12);
            _manualPanel = new ManualOperationPanel();
            _manualTab.Controls.Add(_manualPanel);
            _sourceTabs.TabPages.Add(filePage);
            _sourceTabs.TabPages.Add(_manualTab);

            _shortcutBar = new FlowLayoutPanel();
            _shortcutBar.Dock = DockStyle.Top;
            _shortcutBar.Height = 50;
            _shortcutBar.Padding = new Padding(18, 9, 18, 9);
            _shortcutBar.FlowDirection = FlowDirection.LeftToRight;
            _shortcutBar.WrapContents = false;
            _shortcutBar.BackColor = SystemColors.Control;

            Label hotkeyLabel = new Label();
            hotkeyLabel.AutoSize = true;
            hotkeyLabel.Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold);
            hotkeyLabel.Margin = new Padding(0, 6, 8, 0);
            hotkeyLabel.Text = "\u5168\u5c40\u5feb\u6377\u952e";

            _hotkeyValueLabel = new Label();
            _hotkeyValueLabel.AutoSize = true;
            _hotkeyValueLabel.Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold);
            _hotkeyValueLabel.Margin = new Padding(0, 6, 0, 0);
            _hotkeyValueLabel.Text = _shortcut.DisplayText();

            _changeShortcutButton = new Button();
            _changeShortcutButton.Text = "\u4fee\u6539\u5feb\u6377\u952e";
            _changeShortcutButton.Size = new Size(122, 28);
            _changeShortcutButton.Margin = new Padding(18, 0, 0, 0);
            _changeShortcutButton.Click += ChangeShortcut;

            _shortcutBar.Controls.Add(hotkeyLabel);
            _shortcutBar.Controls.Add(_hotkeyValueLabel);
            _shortcutBar.Controls.Add(_changeShortcutButton);

            Label fileLabel = new Label();
            fileLabel.AutoSize = true;
            fileLabel.Location = new Point(20, 85);
            fileLabel.Text = "\u8f93\u5165\u6587\u4ef6";

            _pathBox = new TextBox();
            _pathBox.ReadOnly = true;
            _pathBox.Location = new Point(105, 81);
            _pathBox.Size = new Size(610, 24);
            _pathBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

            Button browseButton = new Button();
            browseButton.Text = "\u9009\u62e9\u6587\u4ef6...";
            browseButton.Location = new Point(730, 79);
            browseButton.Size = new Size(90, 27);
            browseButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            browseButton.Click += BrowseForFile;

            _intervalCheckBox = new CheckBox();
            _intervalCheckBox.AutoSize = true;
            _intervalCheckBox.Location = new Point(20, 127);
            _intervalCheckBox.Text = "\u6309\u5b57\u7b26\u95f4\u9694\u8f93\u51fa";

            _intervalMillisecondsInput = new NumericUpDown();
            _intervalMillisecondsInput.Location = new Point(165, 124);
            _intervalMillisecondsInput.Size = new Size(65, 24);
            _intervalMillisecondsInput.Minimum = 1;
            _intervalMillisecondsInput.Maximum = 1000;
            _intervalMillisecondsInput.Value = 50;
            _intervalMillisecondsInput.Enabled = false;
            _intervalCheckBox.CheckedChanged += delegate
            {
                _intervalMillisecondsInput.Enabled = _intervalCheckBox.Checked;
            };

            Label intervalUnitLabel = new Label();
            intervalUnitLabel.AutoSize = true;
            intervalUnitLabel.Location = new Point(238, 128);
            intervalUnitLabel.Text = "\u6beb\u79d2 / \u5b57\u7b26\uff081\u20131000\uff09";

            Label instructions = new Label();
            instructions.AutoSize = false;
            instructions.Location = new Point(20, 168);
            instructions.Size = new Size(800, 40);
            instructions.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            instructions.Text = "\u5148\u9009\u62e9\u6587\u672c\u6587\u4ef6\uff0c\u518d\u5207\u6362\u5230\u76ee\u6807\u8f93\u5165\u4f4d\u7f6e\uff0c\u7136\u540e\u6309\u5feb\u6377\u952e\u3002";

            Panel fileFooter = new Panel();
            fileFooter.Dock = DockStyle.Bottom;
            fileFooter.Height = 48;
            fileFooter.BorderStyle = BorderStyle.FixedSingle;
            fileFooter.BackColor = SystemColors.Control;

            _statusLabel = new Label();
            _statusLabel.Dock = DockStyle.Fill;
            _statusLabel.Padding = new Padding(12, 0, 12, 0);
            _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            _statusLabel.AutoEllipsis = true;
            _statusLabel.Text = "\u7b49\u5f85\u9009\u62e9\u6587\u4ef6";
            fileFooter.Controls.Add(_statusLabel);

            filePage.Controls.Add(fileLabel);
            filePage.Controls.Add(_pathBox);
            filePage.Controls.Add(browseButton);
            filePage.Controls.Add(_intervalCheckBox);
            filePage.Controls.Add(_intervalMillisecondsInput);
            filePage.Controls.Add(intervalUnitLabel);
            filePage.Controls.Add(instructions);
            filePage.Controls.Add(fileFooter);
            filePage.Controls.Add(UiChrome.CreatePageHeading(
                "\u6587\u672c\u6587\u4ef6\u8f93\u5165",
                "\u9009\u62e9\u6587\u4ef6\u5e76\u8bbe\u7f6e\u6587\u672c\u8f93\u51fa\u65b9\u5f0f\u3002"));

            Controls.Add(_sourceTabs);
            Controls.Add(_shortcutBar);

            _manualPanel.StopRequested += delegate
            {
                if (_manualRunning)
                {
                    _cancelSending = true;
                    _manualPanel.SetRunState(true, "\u6b63\u5728\u505c\u6b62\u64cd\u4f5c\u6d41\u7a0b\u2026");
                }
            };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!_manualPanel.ConfirmClose())
                {
                    e.Cancel = true;
                    return;
                }
                _cancelSending = true;
            };
        }

        public static void Run()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new KeyboardForm());
        }

        internal void RunSharedChromeSelfTest()
        {
            PerformLayout();
            _shortcutBar.PerformLayout();
            if (_shortcutBar.Parent != this || _sourceTabs.Parent != this ||
                _shortcutBar.Dock != DockStyle.Top || _sourceTabs.Dock != DockStyle.Fill ||
                _hotkeyValueLabel.Parent != _shortcutBar ||
                _changeShortcutButton.Parent != _shortcutBar ||
                _sourceTabs.TabPages.Count != 2 ||
                _changeShortcutButton.Text != "\u4fee\u6539\u5feb\u6377\u952e" ||
                _hotkeyValueLabel.Text != _shortcut.DisplayText() ||
                _shortcutBar.Top != 0 || _sourceTabs.Top < _shortcutBar.Bottom ||
                _sourceTabs.Bottom > ClientSize.Height)
                throw new InvalidOperationException("The shared shortcut header is not connected to both source pages.");
        }

        internal void RunStatusRoutingSelfTest()
        {
            TabPage originalTab = _sourceTabs.SelectedTab;
            string originalFileStatus = _statusLabel.Text;
            string originalManualStatus = _manualPanel.GetStatusTextForSelfTest();
            try
            {
                const string manualMessage = "manual status routing test";
                _sourceTabs.SelectedTab = _manualTab;
                SetStatus(manualMessage);
                if (_statusLabel.Text != originalFileStatus ||
                    _manualPanel.GetStatusTextForSelfTest() != manualMessage)
                    throw new InvalidOperationException("Manual-page status was not isolated from the inactive file page.");

                const string fileMessage = "file status routing test";
                _sourceTabs.SelectedTab = _sourceTabs.TabPages[0];
                SetStatus(fileMessage);
                if (_statusLabel.Text != fileMessage ||
                    _manualPanel.GetStatusTextForSelfTest() != manualMessage)
                    throw new InvalidOperationException("File-page status leaked into the inactive manual page.");
            }
            finally
            {
                _statusLabel.Text = originalFileStatus;
                _manualPanel.SetStatusText(originalManualStatus);
                _sourceTabs.SelectedTab = originalTab;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            if (RegisterShortcut(_shortcut))
            {
                SetStatus("\u5feb\u6377\u952e\u5df2\u5c31\u7eea\uff08" + _shortcut.DisplayText() + "\uff09\uff1b\u8bf7\u9009\u62e9\u6587\u4ef6\u3002");
            }
            else
            {
                SetStatus("\u5feb\u6377\u952e\u6ce8\u518c\u5931\u8d25\uff08Windows \u9519\u8bef\u7801: " + Marshal.GetLastWin32Error() + "\uff09\uff0c\u53ef\u80fd\u5df2\u88ab\u5360\u7528\u3002");
                _manualPanel.SetRunState(false, "\u5168\u5c40\u5feb\u6377\u952e\u6ce8\u518c\u5931\u8d25\uff0c\u8bf7\u4fee\u6539\u5feb\u6377\u952e\u540e\u91cd\u8bd5\u3002");
            }
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            UnregisterCurrentShortcut();
            base.OnHandleDestroyed(e);
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmHotkey && message.WParam.ToInt32() == HotkeyId)
            {
                HandleHotkey();
                return;
            }
            base.WndProc(ref message);
        }

        private void BrowseForFile(object sender, EventArgs e)
        {
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "\u9009\u62e9\u8981\u8f93\u5165\u7684\u6587\u672c\u6587\u4ef6";
                dialog.Filter = "\u6587\u672c\u6587\u4ef6 (*.txt;*.text;*.md;*.csv;*.log)|*.txt;*.text;*.md;*.csv;*.log|\u6240\u6709\u6587\u4ef6 (*.*)|*.*";
                dialog.Multiselect = false;
                dialog.CheckFileExists = true;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    _selectedPath = dialog.FileName;
                    _pathBox.Text = _selectedPath;
                    if (_hotkeyRegistered)
                        SetStatus("\u6587\u4ef6\u5df2\u9009\u4e2d\uff1b\u5207\u6362\u5230\u76ee\u6807\u7a97\u53e3\u540e\u6309 " + _shortcut.DisplayText() + "\u3002");
                    else
                        SetStatus("\u6587\u4ef6\u5df2\u9009\u4e2d\uff0c\u4f46\u5168\u5c40\u5feb\u6377\u952e\u4e0d\u53ef\u7528\u3002");
                }
            }
        }

        private bool RegisterShortcut(ShortcutConfiguration shortcut)
        {
            _hotkeyRegistered = RegisterHotKey(Handle, HotkeyId,
                shortcut.Modifiers | ModNoRepeat, shortcut.VirtualKey);
            return _hotkeyRegistered;
        }

        private void UnregisterCurrentShortcut()
        {
            if (_hotkeyRegistered)
            {
                UnregisterHotKey(Handle, HotkeyId);
                _hotkeyRegistered = false;
            }
        }

        private void ChangeShortcut(object sender, EventArgs e)
        {
            ShortcutConfiguration previous = _shortcut;
            UnregisterCurrentShortcut();
            bool saved = false;
            try
            {
                using (ShortcutDialog dialog = new ShortcutDialog(previous))
                {
                    if (dialog.ShowDialog(this) != DialogResult.OK)
                    {
                        SetStatus("\u5feb\u6377\u952e\u672a\u66f4\u6539\u3002");
                        return;
                    }

                    ShortcutConfiguration updated = dialog.SelectedShortcut;
                    if (!RegisterShortcut(updated))
                    {
                        int error = Marshal.GetLastWin32Error();
                        SetStatus("\u65b0\u5feb\u6377\u952e\u4e0d\u53ef\u7528\uff08Windows \u9519\u8bef\u7801: " + error + "\uff09\uff1b\u53ef\u80fd\u5df2\u88ab\u5360\u7528\u3002");
                        return;
                    }

                    try
                    {
                        updated.Save();
                    }
                    catch (Exception ex)
                    {
                        SetStatus("\u4fdd\u5b58\u5feb\u6377\u952e\u5931\u8d25\uff1a" + ex.Message);
                        return;
                    }

                    _shortcut = updated;
                    _hotkeyValueLabel.Text = _shortcut.DisplayText();
                    saved = true;
                    SetStatus("\u5feb\u6377\u952e\u5df2\u66f4\u65b0\u5e76\u4fdd\u5b58\u3002");
                }
            }
            catch (Exception ex)
            {
                SetStatus("\u8bbe\u7f6e\u5feb\u6377\u952e\u5931\u8d25\uff1a" + ex.Message);
            }
            finally
            {
                if (!saved)
                {
                    UnregisterCurrentShortcut();
                    _shortcut = previous;
                    _hotkeyValueLabel.Text = _shortcut.DisplayText();
                    if (!RegisterShortcut(previous))
                        SetStatus("\u65e0\u6cd5\u6062\u590d\u539f\u5feb\u6377\u952e\uff08Windows \u9519\u8bef\u7801: " + Marshal.GetLastWin32Error() + "\uff09\u3002");
                }
            }
        }

        private void HandleHotkey()
        {
            if (!_hotkeyRegistered)
                return;
            if (_manualRunning)
            {
                _cancelSending = true;
                _manualPanel.SetRunState(true, "\u6536\u5230\u505c\u6b62\u6307\u4ee4\uff0c\u6b63\u5728\u7ed3\u675f\u64cd\u4f5c\u2026");
                return;
            }
            if (_isSending)
            {
                SetStatus("\u6b63\u5728\u9010\u5b57\u7b26\u8f93\u5165\uff0c\u8bf7\u7a0d\u5019\u3002");
                return;
            }
            if (_sourceTabs.SelectedTab == _manualTab)
            {
                if (GetForegroundWindow() == Handle)
                {
                    _manualPanel.SetRunState(false, "\u8bf7\u5148\u5207\u6362\u5230\u76ee\u6807\u7a97\u53e3\uff0c\u518d\u6309\u5feb\u6377\u952e\u6267\u884c\u3002");
                    return;
                }
                StartManualProgram();
                return;
            }
            if (String.IsNullOrEmpty(_selectedPath))
            {
                SetStatus("\u8bf7\u5148\u9009\u62e9\u6587\u672c\u6587\u4ef6\u3002");
                return;
            }

            string text;
            try
            {
                text = KeyboardInput.ReadText(_selectedPath);
            }
            catch (Exception ex)
            {
                SetStatus("\u8bfb\u53d6\u5931\u8d25\uff1a" + ex.Message);
                return;
            }

            if (text.Length == 0)
            {
                SetStatus("\u6587\u4ef6\u5185\u5bb9\u4e3a\u7a7a\u3002");
                return;
            }

            if (!WaitForHotkeyRelease())
            {
                SetStatus("\u8bf7\u5148\u677e\u5f00\u5feb\u6377\u952e\u540e\u91cd\u8bd5\u3002");
                return;
            }

            try
            {
                if (_intervalCheckBox.Checked)
                    StartIntervalSend(text, (int)_intervalMillisecondsInput.Value);
                else
                {
                    KeyboardInput.SendText(text);
                    SetStatus("\u8f93\u5165\u5b8c\u6210\u3002");
                }
            }
            catch (Exception ex)
            {
                SetStatus("\u8f93\u5165\u5931\u8d25\uff1a" + ex.Message);
            }
        }

        private void StartManualProgram()
        {
            ManualProgram program;
            try
            {
                program = _manualPanel.GetProgram();
                ManualProgramValidator.Validate(program, true);
            }
            catch (Exception ex)
            {
                _manualPanel.SetRunState(false, "\u65e0\u6cd5\u8fd0\u884c\uff1a" + ex.Message);
                return;
            }

            if (!WaitForHotkeyRelease())
            {
                _manualPanel.SetRunState(false, "\u8bf7\u5148\u677e\u5f00\u5feb\u6377\u952e\u540e\u91cd\u8bd5\u3002");
                return;
            }

            _isSending = true;
            _manualRunning = true;
            _cancelSending = false;
            _manualPanel.SetRunState(true, "\u6b63\u5728\u8fd0\u884c\u64cd\u4f5c\u6d41\u7a0b\uff1b\u518d\u6b21\u6309\u5feb\u6377\u952e\u53ef\u53d6\u6d88\u3002");

            Thread worker = new Thread(delegate()
            {
                string finalStatus;
                try
                {
                    bool completed = ManualProgramRunner.Run(program,
                        delegate(string text, Func<bool> cancellationRequested)
                        {
                            return KeyboardInput.SendTextCancellable(text, cancellationRequested);
                        },
                        delegate(string chord) { KeyboardInput.SendKeyChord(chord); },
                        delegate { return _cancelSending; },
                        delegate(int milliseconds) { Thread.Sleep(milliseconds); });
                    finalStatus = completed ? "\u64cd\u4f5c\u6d41\u7a0b\u6267\u884c\u5b8c\u6210\u3002" : "\u64cd\u4f5c\u6d41\u7a0b\u5df2\u505c\u6b62\u3002";
                }
                catch (Exception ex)
                {
                    finalStatus = "\u6267\u884c\u5931\u8d25\uff1a" + ex.Message;
                }

                if (!IsDisposed && IsHandleCreated)
                {
                    try
                    {
                        BeginInvoke(new MethodInvoker(delegate
                        {
                            _manualRunning = false;
                            _isSending = false;
                            _manualPanel.SetRunState(false, finalStatus);
                        }));
                    }
                    catch (ObjectDisposedException)
                    {
                        // The form may be disposed while the background sender exits.
                    }
                    catch (InvalidOperationException)
                    {
                        // The form may be closing while the background sender exits.
                    }
                }
            });
            worker.IsBackground = true;
            try
            {
                worker.Start();
            }
            catch (Exception ex)
            {
                _manualRunning = false;
                _isSending = false;
                _manualPanel.SetRunState(false, "\u542f\u52a8\u5931\u8d25\uff1a" + ex.Message);
            }
        }

        private void StartIntervalSend(string text, int intervalMilliseconds)
        {
            _isSending = true;
            _cancelSending = false;
            Thread worker = new Thread(delegate()
            {
                string finalStatus;
                try
                {
                    bool completed = KeyboardInput.SendTextWithInterval(text, intervalMilliseconds,
                        delegate { return _cancelSending; });
                    finalStatus = completed ? "\u8f93\u5165\u5b8c\u6210\u3002" : "\u8f93\u5165\u5df2\u53d6\u6d88\u3002";
                }
                catch (Exception ex)
                {
                    finalStatus = "\u8f93\u5165\u5931\u8d25\uff1a" + ex.Message;
                }

                if (!IsDisposed && IsHandleCreated)
                {
                    try
                    {
                        BeginInvoke(new MethodInvoker(delegate
                        {
                            _isSending = false;
                            SetStatus(finalStatus);
                        }));
                    }
                    catch (ObjectDisposedException)
                    {
                        // The form may be disposed while the background sender exits.
                    }
                    catch (InvalidOperationException)
                    {
                        // The form may be closing while the background sender exits.
                    }
                }
            });
            worker.IsBackground = true;
            try
            {
                worker.Start();
            }
            catch
            {
                _isSending = false;
                throw;
            }
            SetStatus("\u6b63\u5728\u9010\u5b57\u7b26\u8f93\u5165\u2026");
        }

        private bool WaitForHotkeyRelease()
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(2);
            while (DateTime.UtcNow < deadline)
            {
                bool controlDown = (_shortcut.Modifiers & ShortcutConfiguration.ModifierControl) != 0 &&
                    (GetAsyncKeyState(VkControl) & 0x8000) != 0;
                bool altDown = (_shortcut.Modifiers & ShortcutConfiguration.ModifierAlt) != 0 &&
                    (GetAsyncKeyState(VkMenu) & 0x8000) != 0;
                bool shiftDown = (_shortcut.Modifiers & ShortcutConfiguration.ModifierShift) != 0 &&
                    (GetAsyncKeyState(VkShift) & 0x8000) != 0;
                bool triggerDown = (GetAsyncKeyState((int)_shortcut.VirtualKey) & 0x8000) != 0;
                if (!controlDown && !altDown && !shiftDown && !triggerDown)
                {
                    Thread.Sleep(30);
                    return true;
                }
                Thread.Sleep(10);
            }
            return false;
        }

        private void SetStatus(string text)
        {
            if (_sourceTabs.SelectedTab == _manualTab)
                _manualPanel.SetStatusText(text);
            else
                _statusLabel.Text = text;
        }
    }
}
'@

    Add-Type -TypeDefinition $source -ReferencedAssemblies @(
        'System.Windows.Forms.dll',
        'System.Drawing.dll',
        'System.Runtime.Serialization.dll',
        'System.Xml.dll'
    )
}

if ($SelfTest) {
    Write-Output ([SimulateKeyboardInput.KeyboardInput]::RunSelfTests())
    Write-Output ([SimulateKeyboardInput.ManualProgramTests]::RunSelfTests())
    exit 0
}

[SimulateKeyboardInput.KeyboardForm]::Run()
