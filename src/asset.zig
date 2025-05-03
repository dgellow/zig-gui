const std = @import("std");
const ImageHandle = @import("core/image.zig").ImageHandle;
const FontHandle = @import("core/font.zig").FontHandle;
const RendererInterface = @import("renderer.zig").RendererInterface;

/// Types of assets that can be managed
pub const AssetType = enum {
    image,
    font,
    audio,
    text,
    json,
    binary,
    custom,
};

/// Loading state of an asset
pub const AssetState = enum {
    loading,
    loaded,
    failed,
};

/// Asset data for different asset types
pub const Asset = struct {
    type: AssetType,
    state: AssetState,
    data: *anyopaque,
    data_size: usize,
    content_type: []const u8,
    ref_count: u32,

    deinit_fn: *const fn (*Asset) void,

    /// Free resources used by this asset
    pub fn deinit(self: *Asset) void {
        self.deinit_fn(self);
    }
};

/// Handle for accessing assets
pub const AssetHandle = struct {
    manager: *AssetManager,
    path: []const u8,
    state: AssetState,
    asset: ?*Asset,

    /// Check if the asset is loaded
    pub fn isLoaded(self: *const AssetHandle) bool {
        return self.state == .loaded and self.asset != null;
    }

    /// Check if the asset had an error loading
    pub fn hasError(self: *const AssetHandle) bool {
        return self.state == .failed;
    }

    /// Get asset data as a specific type
    pub fn getData(self: *const AssetHandle, comptime T: type) ?*T {
        if (!self.isLoaded()) return null;
        return @ptrCast(@alignCast(self.asset.?.data));
    }

    /// Add a callback for when loading completes
    pub fn addLoadCallback(self: *AssetHandle, callback: fn (*AssetHandle) void) !void {
        return self.manager.addAssetCallback(self, callback);
    }

    /// Release this handle (decrements ref count)
    pub fn release(self: *AssetHandle) void {
        // Delegate to manager
        self.manager.releaseAsset(self.path);

        // Free path memory
        self.manager.allocator.free(self.path);
    }
};

/// Request for loading an asset
const LoadingRequest = struct {
    path: []const u8,
    asset_type: AssetType,
    callback: ?*const fn (*AssetHandle) void,
};

/// Asset callback structure
const AssetCallback = struct {
    handle: *AssetHandle,
    callback: *const fn (*AssetHandle) void,
};

const AssetLoadResult = struct {
    state: AssetState,
    asset: ?*Asset,
};

/// System for managing asset loading and access
pub const AssetManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    loaded_assets: std.StringHashMap(*Asset),
    loading_requests: std.ArrayList(LoadingRequest),
    callbacks: std.ArrayList(AssetCallback),

    renderer: ?*RendererInterface,

    /// Initialize the asset manager
    pub fn init(allocator: std.mem.Allocator) !*AssetManager {
        const manager = try allocator.create(AssetManager);
        manager.* = .{
            .allocator = allocator,
            .loaded_assets = std.StringHashMap(*Asset).init(allocator),
            .loading_requests = std.ArrayList(LoadingRequest).init(allocator),
            .callbacks = std.ArrayList(AssetCallback).init(allocator),
            .renderer = null,
        };
        return manager;
    }

    /// Set the renderer to use for loading assets
    pub fn setRenderer(self: *AssetManager, renderer: *RendererInterface) void {
        self.renderer = renderer;
    }

    /// Free resources used by the asset manager
    pub fn deinit(self: *AssetManager) void {
        // Free all loaded assets
        var asset_it = self.loaded_assets.valueIterator();
        while (asset_it.next()) |asset| {
            asset.*.deinit();
            self.allocator.destroy(asset.*);
        }
        self.loaded_assets.deinit();

        // Free all loading requests
        for (self.loading_requests.items) |request| {
            self.allocator.free(request.path);
        }
        self.loading_requests.deinit();

        // Free callback list
        self.callbacks.deinit();

        // Free self
        self.allocator.destroy(self);
    }

    /// Load an asset and return a handle
    pub fn loadAsset(self: *AssetManager, path: []const u8, asset_type: AssetType) !AssetHandle {
        // Check if already loaded
        if (self.loaded_assets.get(path)) |asset| {
            // Increment reference count
            asset.ref_count += 1;

            return AssetHandle{
                .manager = self,
                .path = try self.allocator.dupe(u8, path),
                .state = asset.state,
                .asset = asset,
            };
        }

        // Create loading request
        const handle = AssetHandle{
            .manager = self,
            .path = try self.allocator.dupe(u8, path),
            .state = .loading,
            .asset = null,
        };

        try self.loading_requests.append(.{
            .path = try self.allocator.dupe(u8, path),
            .asset_type = asset_type,
            .callback = null,
        });

        return handle;
    }

    /// Load an image asset
    pub fn loadImage(self: *AssetManager, path: []const u8) !AssetHandle {
        return self.loadAsset(path, .image);
    }

    /// Load a font asset
    pub fn loadFont(self: *AssetManager, path: []const u8) !AssetHandle {
        return self.loadAsset(path, .font);
    }

    /// Load a text asset
    pub fn loadText(self: *AssetManager, path: []const u8) !AssetHandle {
        return self.loadAsset(path, .text);
    }

    /// Load a JSON asset
    pub fn loadJson(self: *AssetManager, path: []const u8) !AssetHandle {
        return self.loadAsset(path, .json);
    }

    /// Process queued asset loading requests
    pub fn processLoadingRequests(self: *AssetManager) !void {
        if (self.loading_requests.items.len == 0) return;

        // Take a copy of the current requests to process
        const requests = try self.allocator.alloc(LoadingRequest, self.loading_requests.items.len);
        defer self.allocator.free(requests);

        std.mem.copyForwards(LoadingRequest, requests, self.loading_requests.items);
        self.loading_requests.clearRetainingCapacity();

        // Process each request
        for (requests) |request| {
            defer self.allocator.free(request.path);

            // Skip if already loaded
            if (self.loaded_assets.get(request.path)) |_| {
                continue;
            }

            // Try to load the asset
            const result = try self.loadAssetFromPath(request.path, request.asset_type);

            // Create handle for callbacks
            var handle = AssetHandle{
                .manager = self,
                .path = try self.allocator.dupe(u8, request.path),
                .state = result.state,
                .asset = result.asset,
            };

            // Invoke any callbacks waiting for this asset
            self.invokeCallbacksForAsset(&handle);

            // Cleanup handle path if asset failed to load
            if (result.state == .failed) {
                self.allocator.free(handle.path);
            }
        }
    }

    /// Add a callback for when an asset finishes loading
    pub fn addAssetCallback(self: *AssetManager, handle: *AssetHandle, callback: fn (*AssetHandle) void) !void {
        // If asset is already loaded, call immediately
        if (handle.isLoaded()) {
            callback(handle);
            return;
        }

        // Add to callback list
        try self.callbacks.append(.{
            .handle = handle,
            .callback = callback,
        });
    }

    /// Release an asset (decrement reference count)
    pub fn releaseAsset(self: *AssetManager, path: []const u8) void {
        if (self.loaded_assets.getPtr(path)) |asset_ptr| {
            var asset = asset_ptr.*;

            // Decrement reference count
            if (asset.ref_count > 0) {
                asset.ref_count -= 1;
            }

            // If no more references, remove from loaded assets
            if (asset.ref_count == 0) {
                _ = self.loaded_assets.remove(path);
                asset.deinit();
                self.allocator.destroy(asset);
            }
        }
    }

    /// Create an image asset from memory data
    pub fn createImageFromMemory(self: *AssetManager, width: u32, height: u32, data: []const u8, format: anytype) !AssetHandle {
        // Check if we have a renderer
        if (self.renderer == null) {
            return error.RendererNotSet;
        }

        // Generate a unique path
        var seed: u64 = @intFromPtr(data.ptr);
        seed = seed ^ @as(u64, width) << 32 | @as(u64, height);

        const path = try std.fmt.allocPrint(self.allocator, "memory://image/{d}", .{seed});

        // Check if already exists
        if (self.loaded_assets.get(path)) |asset| {
            self.allocator.free(path);

            // Increment reference count
            asset.ref_count += 1;

            return AssetHandle{
                .manager = self,
                .path = try self.allocator.dupe(u8, path),
                .state = asset.state,
                .asset = asset,
            };
        }

        // Create image using renderer
        const image_handle = self.renderer.?.vtable.createImage(self.renderer.?, width, height, format, data) orelse {
            self.allocator.free(path);
            return error.ImageCreationFailed;
        };

        // Create image asset container
        const image_data = try self.allocator.create(ImageHandle);
        image_data.* = image_handle;

        // Create asset
        const asset = try self.allocator.create(Asset);
        asset.* = .{
            .type = .image,
            .state = .loaded,
            .data = image_data,
            .data_size = @sizeOf(ImageHandle),
            .content_type = "image",
            .ref_count = 1,
            .deinit_fn = struct {
                fn deinit(asset_ptr: *Asset) void {
                    // Get image handle
                    const img_handle: *ImageHandle = @ptrCast(@alignCast(asset_ptr.data));

                    // Free image using renderer
                    const hash_map_1: *std.ArrayHashMapUnmanaged([]const u8, *Asset, std.hash_map.StringIndexContext, false) = @fieldParentPtr("entries", asset_ptr);
                    const hash_map_2: *std.StringHashMapUnmanaged(*Asset) = @fieldParentPtr("unmanaged", hash_map_1);
                    const hash_map_3: *std.StringHashMap(*Asset) = @fieldParentPtr("hash_map", hash_map_2);
                    const manager: *Self = @fieldParentPtr("loaded_assets", hash_map_3);

                    if (manager.renderer) |renderer| {
                        renderer.vtable.destroyImage(renderer, img_handle.*);
                    }

                    // Free image handle
                    manager.allocator.destroy(img_handle);
                }
            }.deinit,
        };

        // Store asset
        try self.loaded_assets.put(path, asset);

        // Return handle
        return AssetHandle{
            .manager = self,
            .path = path,
            .state = .loaded,
            .asset = asset,
        };
    }

    /// Load asset from path
    fn loadAssetFromPath(self: *AssetManager, path: []const u8, asset_type: AssetType) !AssetLoadResult {
        // Load the file data
        const file_data = try self.loadFileData(path);
        defer self.allocator.free(file_data);

        // Process based on asset type
        switch (asset_type) {
            .image => {
                // Create image asset
                return self.createImageAsset(path, file_data);
            },
            .font => {
                // Create font asset
                return self.createFontAsset(path, file_data);
            },
            .text => {
                // Create text asset
                return self.createTextAsset(path, file_data);
            },
            .json => {
                // Create JSON asset
                return self.createJsonAsset(path, file_data);
            },
            else => {
                // Create binary asset
                return self.createBinaryAsset(path, file_data);
            },
        }
    }

    /// Load raw file data
    fn loadFileData(self: *AssetManager, path: []const u8) ![]u8 {
        // Open file
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Get file size
        const size = try file.getEndPos();

        // Allocate buffer
        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        // Read file data
        const bytes_read = try file.readAll(buffer);
        if (bytes_read != size) {
            return error.UnexpectedEOF;
        }

        return buffer;
    }

    /// Create an image asset from file data
    fn createImageAsset(self: *AssetManager, path: []const u8, data: []const u8) !AssetLoadResult {
        // Check if we have a renderer
        if (self.renderer == null) {
            return .{ .state = .failed, .asset = null };
        }

        // Determine image format from file extension
        const extension = std.fs.path.extension(path);
        const format = if (std.mem.eql(u8, extension, ".png"))
            @import("core/image.zig").ImageFormat.rgba8888
        else if (std.mem.eql(u8, extension, ".jpg") or std.mem.eql(u8, extension, ".jpeg"))
            @import("core/image.zig").ImageFormat.rgb888
        else
            @import("core/image.zig").ImageFormat.rgba8888;

        // Create image using renderer
        // Note: In a real implementation, you would determine width/height from the image data
        const image_handle = self.renderer.?.vtable.createImage(self.renderer.?, 0, 0, // Size determined by renderer
            format, data) orelse return .{ .state = .failed, .asset = null };

        // Create image asset container
        const image_data = try self.allocator.create(ImageHandle);
        image_data.* = image_handle;

        // Create asset
        const asset = try self.allocator.create(Asset);
        asset.* = .{
            .type = .image,
            .state = .loaded,
            .data = image_data,
            .data_size = @sizeOf(ImageHandle),
            .content_type = "image",
            .ref_count = 1,
            .deinit_fn = struct {
                fn deinit(asset_ptr: *Asset) void {
                    // Get image handle
                    const img_handle: *ImageHandle = @ptrCast(@alignCast(asset_ptr.data));

                    // Free image using renderer
                    const hash_map_1: *std.ArrayHashMapUnmanaged([]const u8, *Asset, std.hash_map.StringIndexContext, false) = @fieldParentPtr("entries", asset_ptr);
                    const hash_map_2: *std.StringHashMapUnmanaged(*Asset) = @fieldParentPtr("unmanaged", hash_map_1);
                    const hash_map_3: *std.StringHashMap(*Asset) = @fieldParentPtr("hash_map", hash_map_2);
                    const self2: *Self = @fieldParentPtr("loaded_assets", hash_map_3);

                    if (self2.renderer) |renderer| {
                        renderer.vtable.destroyImage(renderer, img_handle.*);
                    }

                    // Free image handle
                    self2.allocator.destroy(img_handle);
                }
            }.deinit,
        };

        // Store asset
        try self.loaded_assets.put(path, asset);

        return .{ .state = .loaded, .asset = asset };
    }

    /// Create a font asset from file data
    fn createFontAsset(self: *AssetManager, path: []const u8, data: []const u8) !AssetLoadResult {
        // Check if we have a renderer
        if (self.renderer == null) {
            return .{ .state = .failed, .asset = null };
        }

        // Create font using renderer
        const font_handle = self.renderer.?.vtable.createFont(self.renderer.?, data, 14.0 // Default size
        ) orelse return .{ .state = .failed, .asset = null };

        // Create font asset container
        const font_data = try self.allocator.create(FontHandle);
        font_data.* = font_handle;

        // Create asset
        const asset = try self.allocator.create(Asset);
        asset.* = .{
            .type = .font,
            .state = .loaded,
            .data = font_data,
            .data_size = @sizeOf(FontHandle),
            .content_type = "font",
            .ref_count = 1,
            .deinit_fn = struct {
                fn deinit(asset_ptr: *Asset) void {
                    // Get font handle
                    const fnt_Handle: *FontHandle = @ptrCast(@alignCast(asset_ptr.data));

                    // Free font using renderer
                    const hash_map_1: *std.ArrayHashMapUnmanaged([]const u8, *Asset, std.hash_map.StringIndexContext, false) = @fieldParentPtr("entries", asset_ptr);
                    const hash_map_2: *std.StringHashMapUnmanaged(*Asset) = @fieldParentPtr("unmanaged", hash_map_1);
                    const hash_map_3: *std.StringHashMap(*Asset) = @fieldParentPtr("hash_map", hash_map_2);

                    const self2: *Self = @fieldParentPtr("loaded_assets", hash_map_3);
                    if (self2.renderer) |renderer| {
                        renderer.vtable.destroyFont(renderer, fnt_Handle.*);
                    }

                    // Free font handle
                    self2.allocator.destroy(fnt_Handle);
                }
            }.deinit,
        };

        // Store asset
        try self.loaded_assets.put(path, asset);

        return .{ .state = .loaded, .asset = asset };
    }

    /// Create a text asset
    fn createTextAsset(self: *AssetManager, path: []const u8, data: []const u8) !AssetLoadResult {
        // Copy the text data
        const text_data = try self.allocator.dupe(u8, data);

        // Create asset
        const asset = try self.allocator.create(Asset);
        asset.* = .{
            .type = .text,
            .state = .loaded,
            .data = text_data.ptr,
            .data_size = text_data.len,
            .content_type = "text/plain",
            .ref_count = 1,
            .deinit_fn = struct {
                fn deinit(asset_ptr: *Asset) void {
                    // Free text data
                    const hash_map_1: *std.ArrayHashMapUnmanaged([]const u8, *Asset, std.hash_map.StringIndexContext, false) = @fieldParentPtr("entries", asset_ptr);
                    const hash_map_2: *std.StringHashMapUnmanaged(*Asset) = @fieldParentPtr("unmanaged", hash_map_1);
                    const hash_map_3: *std.StringHashMap(*Asset) = @fieldParentPtr("hash_map", hash_map_2);

                    const self2: *Self = @fieldParentPtr("loaded_assets", hash_map_3);
                    self2.allocator.free(@as([*]u8, asset_ptr.data)[0..asset_ptr.data_size]);
                }
            }.deinit,
        };

        // Store asset
        try self.loaded_assets.put(path, asset);

        return .{ .state = .loaded, .asset = asset };
    }

    /// Create a JSON asset
    fn createJsonAsset(self: *AssetManager, path: []const u8, data: []const u8) !AssetLoadResult {
        // Copy the JSON data
        const json_data = try self.allocator.dupe(u8, data);

        // Create asset
        const asset = try self.allocator.create(Asset);
        asset.* = .{
            .type = .json,
            .state = .loaded,
            .data = json_data.ptr,
            .data_size = json_data.len,
            .content_type = "application/json",
            .ref_count = 1,
            .deinit_fn = struct {
                fn deinit(asset_ptr: *Asset) void {
                    // Free JSON data
                    const hash_map_1: *std.ArrayHashMapUnmanaged([]const u8, *Asset, std.hash_map.StringIndexContext, false) = @fieldParentPtr("entries", asset_ptr);
                    const hash_map_2: *std.StringHashMapUnmanaged(*Asset) = @fieldParentPtr("unmanaged", hash_map_1);
                    const hash_map_3: *std.StringHashMap(*Asset) = @fieldParentPtr("hash_map", hash_map_2);

                    const self2: *Self = @fieldParentPtr("loaded_assets", hash_map_3);
                    self2.allocator.free(@as([*]u8, asset_ptr.data)[0..asset_ptr.data_size]);
                }
            }.deinit,
        };

        // Store asset
        try self.loaded_assets.put(path, asset);

        return .{ .state = .loaded, .asset = asset };
    }

    /// Create a binary asset
    fn createBinaryAsset(self: *AssetManager, path: []const u8, data: []const u8) !AssetLoadResult {
        // Copy the binary data
        const binary_data = try self.allocator.dupe(u8, data);

        // Create asset
        const asset = try self.allocator.create(Asset);
        asset.* = .{
            .type = .binary,
            .state = .loaded,
            .data = binary_data.ptr,
            .data_size = binary_data.len,
            .content_type = "application/octet-stream",
            .ref_count = 1,
            .deinit_fn = struct {
                fn deinit(asset_ptr: *Asset) void {
                    // Free binary data
                    const hash_map_1: *std.ArrayHashMapUnmanaged([]const u8, *Asset, std.hash_map.StringIndexContext, false) = @fieldParentPtr("entries", asset_ptr);
                    const hash_map_2: *std.StringHashMapUnmanaged(*Asset) = @fieldParentPtr("unmanaged", hash_map_1);
                    const hash_map_3: *std.StringHashMap(*Asset) = @fieldParentPtr("hash_map", hash_map_2);

                    const self2: *Self = @fieldParentPtr("loaded_assets", hash_map_3);
                    self2.allocator.free(@as([*]u8, asset_ptr.data)[0..asset_ptr.data_size]);
                }
            }.deinit,
        };

        // Store asset
        try self.loaded_assets.put(path, asset);

        return .{ .state = .loaded, .asset = asset };
    }

    /// Invoke callbacks waiting for an asset
    fn invokeCallbacksForAsset(self: *AssetManager, handle: *AssetHandle) void {
        var i: usize = 0;
        while (i < self.callbacks.items.len) {
            const callback = self.callbacks.items[i];

            if (std.mem.eql(u8, callback.handle.path, handle.path)) {
                // Remove from list
                _ = self.callbacks.swapRemove(i);

                // Call callback
                callback.callback(handle);
            } else {
                i += 1;
            }
        }
    }
};
