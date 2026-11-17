Platform adapters: the only place AppKit, Carbon, CGEvent, FSEvents, ServiceManagement and ApplicationServices
may be imported (ADR-0001). Each file implements one port declared in FlotsamBase/Ports
(NSPasteboard adapter, Carbon hotkey registrar, CGEventTap key source, FSEvents folder source,
permission probe, frontmost-app provider). Added with the FRD that needs them (ADR-0011).
