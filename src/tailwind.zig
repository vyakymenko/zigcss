const std = @import("std");

pub const UtilityDeclaration = struct {
    property: []const u8,
    value: []const u8,
};

pub const TailwindRegistry = struct {
    utilities: std.StringHashMap([]const UtilityDeclaration),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TailwindRegistry {
        var registry = TailwindRegistry{
            .utilities = std.StringHashMap([]const UtilityDeclaration).init(allocator),
            .allocator = allocator,
        };
        try registry.registerDefaults();
        return registry;
    }

    pub fn deinit(self: *TailwindRegistry) void {
        var it = self.utilities.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |decl| {
                self.allocator.free(decl.property);
                self.allocator.free(decl.value);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.utilities.deinit();
    }

    fn registerDefaults(self: *TailwindRegistry) !void {
        try self.registerSpacing();
        try self.registerColors();
        try self.registerTypography();
        try self.registerLayout();
        try self.registerFlexbox();
        try self.registerGrid();
        try self.registerBorders();
        try self.registerEffects();
    }

    fn registerSpacing(self: *TailwindRegistry) !void {
        const spacing_map = [_]struct { []const u8, []const u8 }{
            .{ "px-0", "padding-left: 0; padding-right: 0" },
            .{ "px-1", "padding-left: 0.25rem; padding-right: 0.25rem" },
            .{ "px-2", "padding-left: 0.5rem; padding-right: 0.5rem" },
            .{ "px-3", "padding-left: 0.75rem; padding-right: 0.75rem" },
            .{ "px-4", "padding-left: 1rem; padding-right: 1rem" },
            .{ "px-5", "padding-left: 1.25rem; padding-right: 1.25rem" },
            .{ "px-6", "padding-left: 1.5rem; padding-right: 1.5rem" },
            .{ "px-8", "padding-left: 2rem; padding-right: 2rem" },
            .{ "px-10", "padding-left: 2.5rem; padding-right: 2.5rem" },
            .{ "px-12", "padding-left: 3rem; padding-right: 3rem" },
            .{ "px-16", "padding-left: 4rem; padding-right: 4rem" },
            .{ "px-20", "padding-left: 5rem; padding-right: 5rem" },
            .{ "px-24", "padding-left: 6rem; padding-right: 6rem" },
            .{ "px-32", "padding-left: 8rem; padding-right: 8rem" },
            .{ "px-40", "padding-left: 10rem; padding-right: 10rem" },
            .{ "px-48", "padding-left: 12rem; padding-right: 12rem" },
            .{ "px-64", "padding-left: 16rem; padding-right: 16rem" },
            .{ "px-px", "padding-left: 1px; padding-right: 1px" },

            .{ "py-0", "padding-top: 0; padding-bottom: 0" },
            .{ "py-1", "padding-top: 0.25rem; padding-bottom: 0.25rem" },
            .{ "py-2", "padding-top: 0.5rem; padding-bottom: 0.5rem" },
            .{ "py-3", "padding-top: 0.75rem; padding-bottom: 0.75rem" },
            .{ "py-4", "padding-top: 1rem; padding-bottom: 1rem" },
            .{ "py-5", "padding-top: 1.25rem; padding-bottom: 1.25rem" },
            .{ "py-6", "padding-top: 1.5rem; padding-bottom: 1.5rem" },
            .{ "py-8", "padding-top: 2rem; padding-bottom: 2rem" },
            .{ "py-10", "padding-top: 2.5rem; padding-bottom: 2.5rem" },
            .{ "py-12", "padding-top: 3rem; padding-bottom: 3rem" },
            .{ "py-16", "padding-top: 4rem; padding-bottom: 4rem" },
            .{ "py-20", "padding-top: 5rem; padding-bottom: 5rem" },
            .{ "py-24", "padding-top: 6rem; padding-bottom: 6rem" },
            .{ "py-32", "padding-top: 8rem; padding-bottom: 8rem" },
            .{ "py-40", "padding-top: 10rem; padding-bottom: 10rem" },
            .{ "py-48", "padding-top: 12rem; padding-bottom: 12rem" },
            .{ "py-64", "padding-top: 16rem; padding-bottom: 16rem" },
            .{ "py-px", "padding-top: 1px; padding-bottom: 1px" },

            .{ "pt-0", "padding-top: 0" },
            .{ "pt-1", "padding-top: 0.25rem" },
            .{ "pt-2", "padding-top: 0.5rem" },
            .{ "pt-3", "padding-top: 0.75rem" },
            .{ "pt-4", "padding-top: 1rem" },
            .{ "pt-5", "padding-top: 1.25rem" },
            .{ "pt-6", "padding-top: 1.5rem" },
            .{ "pt-8", "padding-top: 2rem" },
            .{ "pt-10", "padding-top: 2.5rem" },
            .{ "pt-12", "padding-top: 3rem" },
            .{ "pt-16", "padding-top: 4rem" },
            .{ "pt-20", "padding-top: 5rem" },
            .{ "pt-24", "padding-top: 6rem" },
            .{ "pt-32", "padding-top: 8rem" },
            .{ "pt-40", "padding-top: 10rem" },
            .{ "pt-48", "padding-top: 12rem" },
            .{ "pt-64", "padding-top: 16rem" },
            .{ "pt-px", "padding-top: 1px" },

            .{ "pr-0", "padding-right: 0" },
            .{ "pr-1", "padding-right: 0.25rem" },
            .{ "pr-2", "padding-right: 0.5rem" },
            .{ "pr-3", "padding-right: 0.75rem" },
            .{ "pr-4", "padding-right: 1rem" },
            .{ "pr-5", "padding-right: 1.25rem" },
            .{ "pr-6", "padding-right: 1.5rem" },
            .{ "pr-8", "padding-right: 2rem" },
            .{ "pr-10", "padding-right: 2.5rem" },
            .{ "pr-12", "padding-right: 3rem" },
            .{ "pr-16", "padding-right: 4rem" },
            .{ "pr-20", "padding-right: 5rem" },
            .{ "pr-24", "padding-right: 6rem" },
            .{ "pr-32", "padding-right: 8rem" },
            .{ "pr-40", "padding-right: 10rem" },
            .{ "pr-48", "padding-right: 12rem" },
            .{ "pr-64", "padding-right: 16rem" },
            .{ "pr-px", "padding-right: 1px" },

            .{ "pb-0", "padding-bottom: 0" },
            .{ "pb-1", "padding-bottom: 0.25rem" },
            .{ "pb-2", "padding-bottom: 0.5rem" },
            .{ "pb-3", "padding-bottom: 0.75rem" },
            .{ "pb-4", "padding-bottom: 1rem" },
            .{ "pb-5", "padding-bottom: 1.25rem" },
            .{ "pb-6", "padding-bottom: 1.5rem" },
            .{ "pb-8", "padding-bottom: 2rem" },
            .{ "pb-10", "padding-bottom: 2.5rem" },
            .{ "pb-12", "padding-bottom: 3rem" },
            .{ "pb-16", "padding-bottom: 4rem" },
            .{ "pb-20", "padding-bottom: 5rem" },
            .{ "pb-24", "padding-bottom: 6rem" },
            .{ "pb-32", "padding-bottom: 8rem" },
            .{ "pb-40", "padding-bottom: 10rem" },
            .{ "pb-48", "padding-bottom: 12rem" },
            .{ "pb-64", "padding-bottom: 16rem" },
            .{ "pb-px", "padding-bottom: 1px" },

            .{ "pl-0", "padding-left: 0" },
            .{ "pl-1", "padding-left: 0.25rem" },
            .{ "pl-2", "padding-left: 0.5rem" },
            .{ "pl-3", "padding-left: 0.75rem" },
            .{ "pl-4", "padding-left: 1rem" },
            .{ "pl-5", "padding-left: 1.25rem" },
            .{ "pl-6", "padding-left: 1.5rem" },
            .{ "pl-8", "padding-left: 2rem" },
            .{ "pl-10", "padding-left: 2.5rem" },
            .{ "pl-12", "padding-left: 3rem" },
            .{ "pl-16", "padding-left: 4rem" },
            .{ "pl-20", "padding-left: 5rem" },
            .{ "pl-24", "padding-left: 6rem" },
            .{ "pl-32", "padding-left: 8rem" },
            .{ "pl-40", "padding-left: 10rem" },
            .{ "pl-48", "padding-left: 12rem" },
            .{ "pl-64", "padding-left: 16rem" },
            .{ "pl-px", "padding-left: 1px" },

            .{ "p-0", "padding: 0" },
            .{ "p-1", "padding: 0.25rem" },
            .{ "p-2", "padding: 0.5rem" },
            .{ "p-3", "padding: 0.75rem" },
            .{ "p-4", "padding: 1rem" },
            .{ "p-5", "padding: 1.25rem" },
            .{ "p-6", "padding: 1.5rem" },
            .{ "p-8", "padding: 2rem" },
            .{ "p-10", "padding: 2.5rem" },
            .{ "p-12", "padding: 3rem" },
            .{ "p-16", "padding: 4rem" },
            .{ "p-20", "padding: 5rem" },
            .{ "p-24", "padding: 6rem" },
            .{ "p-32", "padding: 8rem" },
            .{ "p-40", "padding: 10rem" },
            .{ "p-48", "padding: 12rem" },
            .{ "p-64", "padding: 16rem" },
            .{ "p-px", "padding: 1px" },

            .{ "m-0", "margin: 0" },
            .{ "m-1", "margin: 0.25rem" },
            .{ "m-2", "margin: 0.5rem" },
            .{ "m-3", "margin: 0.75rem" },
            .{ "m-4", "margin: 1rem" },
            .{ "m-5", "margin: 1.25rem" },
            .{ "m-6", "margin: 1.5rem" },
            .{ "m-8", "margin: 2rem" },
            .{ "m-10", "margin: 2.5rem" },
            .{ "m-12", "margin: 3rem" },
            .{ "m-16", "margin: 4rem" },
            .{ "m-20", "margin: 5rem" },
            .{ "m-24", "margin: 6rem" },
            .{ "m-32", "margin: 8rem" },
            .{ "m-40", "margin: 10rem" },
            .{ "m-48", "margin: 12rem" },
            .{ "m-64", "margin: 16rem" },
            .{ "m-auto", "margin: auto" },
            .{ "m-px", "margin: 1px" },

            .{ "mx-0", "margin-left: 0; margin-right: 0" },
            .{ "mx-1", "margin-left: 0.25rem; margin-right: 0.25rem" },
            .{ "mx-2", "margin-left: 0.5rem; margin-right: 0.5rem" },
            .{ "mx-3", "margin-left: 0.75rem; margin-right: 0.75rem" },
            .{ "mx-4", "margin-left: 1rem; margin-right: 1rem" },
            .{ "mx-auto", "margin-left: auto; margin-right: auto" },
            .{ "mx-px", "margin-left: 1px; margin-right: 1px" },

            .{ "my-0", "margin-top: 0; margin-bottom: 0" },
            .{ "my-1", "margin-top: 0.25rem; margin-bottom: 0.25rem" },
            .{ "my-2", "margin-top: 0.5rem; margin-bottom: 0.5rem" },
            .{ "my-3", "margin-top: 0.75rem; margin-bottom: 0.75rem" },
            .{ "my-4", "margin-top: 1rem; margin-bottom: 1rem" },
            .{ "my-auto", "margin-top: auto; margin-bottom: auto" },
            .{ "my-px", "margin-top: 1px; margin-bottom: 1px" },
        };

        for (spacing_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerColors(self: *TailwindRegistry) !void {
        const color_map = [_]struct { []const u8, []const u8 }{
            .{ "text-black", "color: #000" },
            .{ "text-white", "color: #fff" },
            .{ "text-gray-50", "color: #f9fafb" },
            .{ "text-gray-100", "color: #f3f4f6" },
            .{ "text-gray-200", "color: #e5e7eb" },
            .{ "text-gray-300", "color: #d1d5db" },
            .{ "text-gray-400", "color: #9ca3af" },
            .{ "text-gray-500", "color: #6b7280" },
            .{ "text-gray-600", "color: #4b5563" },
            .{ "text-gray-700", "color: #374151" },
            .{ "text-gray-800", "color: #1f2937" },
            .{ "text-gray-900", "color: #111827" },
            .{ "text-red-500", "color: #ef4444" },
            .{ "text-red-600", "color: #dc2626" },
            .{ "text-blue-500", "color: #3b82f6" },
            .{ "text-blue-600", "color: #2563eb" },
            .{ "text-green-500", "color: #22c55e" },
            .{ "text-green-600", "color: #16a34a" },
            .{ "text-yellow-500", "color: #eab308" },
            .{ "text-yellow-600", "color: #ca8a04" },
            .{ "text-purple-500", "color: #a855f7" },
            .{ "text-purple-600", "color: #9333ea" },

            .{ "bg-black", "background-color: #000" },
            .{ "bg-white", "background-color: #fff" },
            .{ "bg-gray-50", "background-color: #f9fafb" },
            .{ "bg-gray-100", "background-color: #f3f4f6" },
            .{ "bg-gray-200", "background-color: #e5e7eb" },
            .{ "bg-gray-300", "background-color: #d1d5db" },
            .{ "bg-gray-400", "background-color: #9ca3af" },
            .{ "bg-gray-500", "background-color: #6b7280" },
            .{ "bg-gray-600", "background-color: #4b5563" },
            .{ "bg-gray-700", "background-color: #374151" },
            .{ "bg-gray-800", "background-color: #1f2937" },
            .{ "bg-gray-900", "background-color: #111827" },
            .{ "bg-red-500", "background-color: #ef4444" },
            .{ "bg-red-600", "background-color: #dc2626" },
            .{ "bg-blue-500", "background-color: #3b82f6" },
            .{ "bg-blue-600", "background-color: #2563eb" },
            .{ "bg-green-500", "background-color: #22c55e" },
            .{ "bg-green-600", "background-color: #16a34a" },
            .{ "bg-yellow-500", "background-color: #eab308" },
            .{ "bg-yellow-600", "background-color: #ca8a04" },
            .{ "bg-purple-500", "background-color: #a855f7" },
            .{ "bg-purple-600", "background-color: #9333ea" },
            .{ "bg-transparent", "background-color: transparent" },
        };

        for (color_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerTypography(self: *TailwindRegistry) !void {
        const typography_map = [_]struct { []const u8, []const u8 }{
            .{ "text-xs", "font-size: 0.75rem; line-height: 1rem" },
            .{ "text-sm", "font-size: 0.875rem; line-height: 1.25rem" },
            .{ "text-base", "font-size: 1rem; line-height: 1.5rem" },
            .{ "text-lg", "font-size: 1.125rem; line-height: 1.75rem" },
            .{ "text-xl", "font-size: 1.25rem; line-height: 1.75rem" },
            .{ "text-2xl", "font-size: 1.5rem; line-height: 2rem" },
            .{ "text-3xl", "font-size: 1.875rem; line-height: 2.25rem" },
            .{ "text-4xl", "font-size: 2.25rem; line-height: 2.5rem" },
            .{ "text-5xl", "font-size: 3rem; line-height: 1" },
            .{ "text-6xl", "font-size: 3.75rem; line-height: 1" },
            .{ "text-7xl", "font-size: 4.5rem; line-height: 1" },
            .{ "text-8xl", "font-size: 6rem; line-height: 1" },
            .{ "text-9xl", "font-size: 8rem; line-height: 1" },

            .{ "font-thin", "font-weight: 100" },
            .{ "font-extralight", "font-weight: 200" },
            .{ "font-light", "font-weight: 300" },
            .{ "font-normal", "font-weight: 400" },
            .{ "font-medium", "font-weight: 500" },
            .{ "font-semibold", "font-weight: 600" },
            .{ "font-bold", "font-weight: 700" },
            .{ "font-extrabold", "font-weight: 800" },
            .{ "font-black", "font-weight: 900" },

            .{ "italic", "font-style: italic" },
            .{ "not-italic", "font-style: normal" },

            .{ "uppercase", "text-transform: uppercase" },
            .{ "lowercase", "text-transform: lowercase" },
            .{ "capitalize", "text-transform: capitalize" },
            .{ "normal-case", "text-transform: none" },

            .{ "underline", "text-decoration: underline" },
            .{ "line-through", "text-decoration: line-through" },
            .{ "no-underline", "text-decoration: none" },
        };

        for (typography_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerLayout(self: *TailwindRegistry) !void {
        const layout_map = [_]struct { []const u8, []const u8 }{
            .{ "block", "display: block" },
            .{ "inline-block", "display: inline-block" },
            .{ "inline", "display: inline" },
            .{ "flex", "display: flex" },
            .{ "inline-flex", "display: inline-flex" },
            .{ "grid", "display: grid" },
            .{ "inline-grid", "display: inline-grid" },
            .{ "hidden", "display: none" },

            .{ "w-full", "width: 100%" },
            .{ "w-screen", "width: 100vw" },
            .{ "w-auto", "width: auto" },
            .{ "w-1/2", "width: 50%" },
            .{ "w-1/3", "width: 33.333333%" },
            .{ "w-2/3", "width: 66.666667%" },
            .{ "w-1/4", "width: 25%" },
            .{ "w-3/4", "width: 75%" },

            .{ "h-full", "height: 100%" },
            .{ "h-screen", "height: 100vh" },
            .{ "h-auto", "height: auto" },

            .{ "overflow-auto", "overflow: auto" },
            .{ "overflow-hidden", "overflow: hidden" },
            .{ "overflow-visible", "overflow: visible" },
            .{ "overflow-scroll", "overflow: scroll" },
        };

        for (layout_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerFlexbox(self: *TailwindRegistry) !void {
        const flexbox_map = [_]struct { []const u8, []const u8 }{
            .{ "flex-row", "flex-direction: row" },
            .{ "flex-col", "flex-direction: column" },
            .{ "flex-row-reverse", "flex-direction: row-reverse" },
            .{ "flex-col-reverse", "flex-direction: column-reverse" },

            .{ "flex-wrap", "flex-wrap: wrap" },
            .{ "flex-nowrap", "flex-wrap: nowrap" },
            .{ "flex-wrap-reverse", "flex-wrap: wrap-reverse" },

            .{ "items-start", "align-items: flex-start" },
            .{ "items-end", "align-items: flex-end" },
            .{ "items-center", "align-items: center" },
            .{ "items-baseline", "align-items: baseline" },
            .{ "items-stretch", "align-items: stretch" },

            .{ "justify-start", "justify-content: flex-start" },
            .{ "justify-end", "justify-content: flex-end" },
            .{ "justify-center", "justify-content: center" },
            .{ "justify-between", "justify-content: space-between" },
            .{ "justify-around", "justify-content: space-around" },
            .{ "justify-evenly", "justify-content: space-evenly" },
        };

        for (flexbox_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerGrid(self: *TailwindRegistry) !void {
        const grid_map = [_]struct { []const u8, []const u8 }{
            .{ "grid-cols-1", "grid-template-columns: repeat(1, minmax(0, 1fr))" },
            .{ "grid-cols-2", "grid-template-columns: repeat(2, minmax(0, 1fr))" },
            .{ "grid-cols-3", "grid-template-columns: repeat(3, minmax(0, 1fr))" },
            .{ "grid-cols-4", "grid-template-columns: repeat(4, minmax(0, 1fr))" },
            .{ "grid-cols-5", "grid-template-columns: repeat(5, minmax(0, 1fr))" },
            .{ "grid-cols-6", "grid-template-columns: repeat(6, minmax(0, 1fr))" },
            .{ "grid-cols-12", "grid-template-columns: repeat(12, minmax(0, 1fr))" },
        };

        for (grid_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerBorders(self: *TailwindRegistry) !void {
        const border_map = [_]struct { []const u8, []const u8 }{
            .{ "border", "border-width: 1px" },
            .{ "border-0", "border-width: 0" },
            .{ "border-2", "border-width: 2px" },
            .{ "border-4", "border-width: 4px" },
            .{ "border-8", "border-width: 8px" },

            .{ "border-solid", "border-style: solid" },
            .{ "border-dashed", "border-style: dashed" },
            .{ "border-dotted", "border-style: dotted" },
            .{ "border-none", "border-style: none" },

            .{ "rounded", "border-radius: 0.25rem" },
            .{ "rounded-sm", "border-radius: 0.125rem" },
            .{ "rounded-md", "border-radius: 0.375rem" },
            .{ "rounded-lg", "border-radius: 0.5rem" },
            .{ "rounded-xl", "border-radius: 0.75rem" },
            .{ "rounded-2xl", "border-radius: 1rem" },
            .{ "rounded-3xl", "border-radius: 1.5rem" },
            .{ "rounded-full", "border-radius: 9999px" },
            .{ "rounded-none", "border-radius: 0" },
        };

        for (border_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn registerEffects(self: *TailwindRegistry) !void {
        const effects_map = [_]struct { []const u8, []const u8 }{
            .{ "shadow-sm", "box-shadow: 0 1px 2px 0 rgb(0 0 0 / 0.05)" },
            .{ "shadow", "box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)" },
            .{ "shadow-md", "box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1)" },
            .{ "shadow-lg", "box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1)" },
            .{ "shadow-xl", "box-shadow: 0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1)" },
            .{ "shadow-2xl", "box-shadow: 0 25px 50px -12px rgb(0 0 0 / 0.25)" },
            .{ "shadow-none", "box-shadow: none" },

            .{ "opacity-0", "opacity: 0" },
            .{ "opacity-25", "opacity: 0.25" },
            .{ "opacity-50", "opacity: 0.5" },
            .{ "opacity-75", "opacity: 0.75" },
            .{ "opacity-100", "opacity: 1" },
        };

        for (effects_map) |entry| {
            const key = try self.allocator.dupe(u8, entry[0]);
            errdefer self.allocator.free(key);
            const declarations = try self.parseDeclarations(entry[1]);
            try self.utilities.put(key, declarations);
        }
    }

    fn parseDeclarations(self: *TailwindRegistry, css: []const u8) ![]const UtilityDeclaration {
        var declarations = try std.ArrayList(UtilityDeclaration).initCapacity(self.allocator, 4);
        errdefer declarations.deinit(self.allocator);

        var i: usize = 0;
        while (i < css.len) {
            while (i < css.len and std.ascii.isWhitespace(css[i])) {
                i += 1;
            }
            if (i >= css.len) break;

            const prop_start = i;
            while (i < css.len and css[i] != ':') {
                i += 1;
            }
            if (i >= css.len) break;

            const property = std.mem.trim(u8, css[prop_start..i], " \t");
            i += 1;

            while (i < css.len and std.ascii.isWhitespace(css[i])) {
                i += 1;
            }

            const value_start = i;
            while (i < css.len and css[i] != ';') {
                i += 1;
            }

            const value = std.mem.trim(u8, css[value_start..i], " \t");
            i += 1;

            const prop_copy = try self.allocator.dupe(u8, property);
            errdefer self.allocator.free(prop_copy);
            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            try declarations.append(self.allocator, UtilityDeclaration{
                .property = prop_copy,
                .value = value_copy,
            });
        }

        return try declarations.toOwnedSlice(self.allocator);
    }

    pub fn expandUtility(self: *const TailwindRegistry, utility: []const u8) ?[]const UtilityDeclaration {
        return self.utilities.get(utility);
    }

    pub fn expandApply(self: *const TailwindRegistry, allocator: std.mem.Allocator, apply_content: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, apply_content.len * 2);
        errdefer result.deinit(allocator);

        var utilities = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        defer {
            for (utilities.items) |util| {
                allocator.free(util);
            }
            utilities.deinit(allocator);
        }

        var i: usize = 0;
        while (i < apply_content.len) {
            while (i < apply_content.len and std.ascii.isWhitespace(apply_content[i])) {
                i += 1;
            }
            if (i >= apply_content.len) break;

            const util_start = i;
            while (i < apply_content.len and !std.ascii.isWhitespace(apply_content[i])) {
                i += 1;
            }

            const utility = std.mem.trim(u8, apply_content[util_start..i], " \t");
            if (utility.len > 0) {
                const util_copy = try allocator.dupe(u8, utility);
                try utilities.append(allocator, util_copy);
            }
        }

        for (utilities.items) |utility| {
            if (self.expandUtility(utility)) |decls| {
                for (decls) |decl| {
                    try result.writer(allocator).print("{s}: {s}; ", .{ decl.property, decl.value });
                }
            }
        }

        return try result.toOwnedSlice(allocator);
    }
};

test "expand spacing utilities" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = try TailwindRegistry.init(allocator);
    defer registry.deinit();

    const px4 = registry.expandUtility("px-4");
    try std.testing.expect(px4 != null);
    try std.testing.expect(px4.?.len == 2);
    try std.testing.expect(std.mem.eql(u8, px4.?[0].property, "padding-left"));
    try std.testing.expect(std.mem.eql(u8, px4.?[0].value, "1rem"));
}

test "expand apply directive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = try TailwindRegistry.init(allocator);
    defer registry.deinit();

    const expanded = try registry.expandApply(allocator, "px-4 py-2");
    defer allocator.free(expanded);

    try std.testing.expect(std.mem.containsAtLeast(u8, expanded, 1, "padding-left"));
    try std.testing.expect(std.mem.containsAtLeast(u8, expanded, 1, "padding-top"));
}
