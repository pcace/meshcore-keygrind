const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const spirv = @import("spirv");
const mod = @import("mod.zig");
const Pattern = mod.Pattern;
const FoundKey = mod.FoundKey;
const GpuPatternConfig = mod.GpuPatternConfig;
const GpuResultBuffer = mod.GpuResultBuffer;
const BATCH_SIZE = mod.BATCH_SIZE;

/// Dynamic Vulkan loader - loads libvulkan/MoltenVK at runtime
const VulkanLoader = struct {
    lib: std.DynLib,
    getProcAddr: vk.PfnGetInstanceProcAddr,

    fn load() !VulkanLoader {
        const lib_names = switch (builtin.os.tag) {
            .macos => &[_][]const u8{ "libMoltenVK.dylib", "libvulkan.1.dylib", "libvulkan.dylib" },
            .linux => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
            .windows => &[_][]const u8{ "vulkan-1.dll" },
            else => return error.UnsupportedPlatform,
        };

        for (lib_names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr")) |proc| {
                return .{
                    .lib = lib,
                    .getProcAddr = proc,
                };
            }
            lib.close();
        }
        return error.VulkanNotFound;
    }
};

var vulkan_loader: ?VulkanLoader = null;

/// Get the Vulkan instance loader function (loads library on first call)
fn getVkGetInstanceProcAddr() !vk.PfnGetInstanceProcAddr {
    if (vulkan_loader) |loader| {
        return loader.getProcAddr;
    }
    vulkan_loader = try VulkanLoader.load();
    return vulkan_loader.?.getProcAddr;
}

/// Vulkan compute grinder for cross-platform GPU vanity search
pub const VulkanGrinder = struct {
    // Vulkan handles
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    compute_queue: vk.Queue,
    compute_queue_family: u32,

    // Pipeline
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    compute_pipeline: vk.Pipeline,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    shader_module: vk.ShaderModule,

    // Command buffer
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,

    // Buffers
    state_buffer: BufferAllocation,
    pattern_buffer: BufferAllocation,
    result_buffer: BufferAllocation,
    found_flag_buffer: BufferAllocation,

    // State
    pattern: Pattern,
    attempts: std.atomic.Value(u64),
    start_time: i64,
    allocator: std.mem.Allocator,
    cpu_prng: std.Random.Xoshiro256,
    threads_per_group: usize,
    p50_attempts: f64,

    // Vulkan API wrappers
    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,

    const Self = @This();

    const BufferAllocation = struct {
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,
        size: vk.DeviceSize,
        mapped: ?*anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, pattern: Pattern, threads_per_group_override: ?usize) !Self {
        // Load base Vulkan functions (dynamically loads Vulkan library)
        const vkb = vk.BaseWrapper.load(try getVkGetInstanceProcAddr());

        // Create instance
        const app_info = vk.ApplicationInfo{
            .p_application_name = "grincel",
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = "grincel",
            .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        };

        const instance = vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
        }, null) catch |err| {
            std.debug.print("Failed to create Vulkan instance: {any}\n", .{err});
            return error.InstanceCreationFailed;
        };

        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);

        errdefer vki.destroyInstance(instance, null);

        // Enumerate physical devices
        var device_count: u32 = 0;
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);
        if (device_count == 0) {
            std.debug.print("No Vulkan devices found\n", .{});
            return error.NoVulkanDevice;
        }

        var physical_devices: [16]vk.PhysicalDevice = undefined;
        device_count = @min(device_count, 16);
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, &physical_devices);

        // Find a device with compute queue
        var selected_device: ?vk.PhysicalDevice = null;
        var selected_queue_family: u32 = 0;

        for (physical_devices[0..device_count]) |pdev| {
            const props = vki.getPhysicalDeviceProperties(pdev);
            std.debug.print("Found device: {s}\n", .{std.mem.sliceTo(&props.device_name, 0)});

            var queue_count: u32 = 0;
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, null);

            var queue_props: [32]vk.QueueFamilyProperties = undefined;
            queue_count = @min(queue_count, 32);
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, &queue_props);

            for (queue_props[0..queue_count], 0..) |qp, i| {
                if (qp.queue_flags.compute_bit) {
                    selected_device = pdev;
                    selected_queue_family = @intCast(i);
                    break;
                }
            }
            if (selected_device != null) break;
        }

        const physical_device = selected_device orelse {
            std.debug.print("No device with compute queue found\n", .{});
            return error.NoComputeQueue;
        };

        const device_props = vki.getPhysicalDeviceProperties(physical_device);
        std.debug.print("Vulkan Device: {s}\n", .{std.mem.sliceTo(&device_props.device_name, 0)});

        // Create logical device
        const queue_priority: f32 = 1.0;
        const queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = selected_queue_family,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&queue_priority),
        };

        const device = vki.createDevice(physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_create_info),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            .p_enabled_features = null,
        }, null) catch |err| {
            std.debug.print("Failed to create device: {any}\n", .{err});
            return error.DeviceCreationFailed;
        };

        const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);

        errdefer vkd.destroyDevice(device, null);

        const compute_queue = vkd.getDeviceQueue(device, selected_queue_family, 0);

        // Create shader module from embedded SPIR-V
        std.debug.print("Shader size: {d} bytes (embedded SPIR-V)\n", .{spirv.EMBEDDED_SPIRV.len});

        const shader_module = vkd.createShaderModule(device, &.{
            .code_size = spirv.EMBEDDED_SPIRV.len,
            .p_code = @ptrCast(@alignCast(spirv.EMBEDDED_SPIRV.ptr)),
        }, null) catch |err| {
            std.debug.print("Failed to create shader module: {any}\n", .{err});
            return error.ShaderModuleCreationFailed;
        };

        errdefer vkd.destroyShaderModule(device, shader_module, null);

        // Create descriptor set layout (4 storage buffers)
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };

        const descriptor_set_layout = vkd.createDescriptorSetLayout(device, &.{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        }, null) catch |err| {
            std.debug.print("Failed to create descriptor set layout: {any}\n", .{err});
            return error.DescriptorSetLayoutCreationFailed;
        };

        errdefer vkd.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

        // Create pipeline layout
        const pipeline_layout = vkd.createPipelineLayout(device, &.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        }, null) catch |err| {
            std.debug.print("Failed to create pipeline layout: {any}\n", .{err});
            return error.PipelineLayoutCreationFailed;
        };

        errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

        // Create compute pipeline
        var compute_pipeline: vk.Pipeline = undefined;
        const pipeline_info = vk.ComputePipelineCreateInfo{
            .stage = .{
                .stage = .{ .compute_bit = true },
                .module = shader_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        _ = vkd.createComputePipelines(device, .null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&compute_pipeline)) catch |err| {
            std.debug.print("Failed to create compute pipeline: {any}\n", .{err});
            return error.ComputePipelineCreationFailed;
        };

        errdefer vkd.destroyPipeline(device, compute_pipeline, null);

        // Get memory properties
        const mem_props = vki.getPhysicalDeviceMemoryProperties(physical_device);

        // Create buffers
        const state_buffer = try createBuffer(vkd, device, &mem_props, 16);
        errdefer destroyBuffer(vkd, device, state_buffer);

        const pattern_buffer = try createBuffer(vkd, device, &mem_props, @sizeOf(GpuPatternConfig));
        errdefer destroyBuffer(vkd, device, pattern_buffer);

        const result_buffer = try createBuffer(vkd, device, &mem_props, @sizeOf(GpuResultBuffer));
        errdefer destroyBuffer(vkd, device, result_buffer);

        const found_flag_buffer = try createBuffer(vkd, device, &mem_props, 4);
        errdefer destroyBuffer(vkd, device, found_flag_buffer);

        // Initialize pattern buffer
        const pattern_ptr: *GpuPatternConfig = @ptrCast(@alignCast(pattern_buffer.mapped));
        pattern_ptr.* = GpuPatternConfig.fromPattern(pattern);

        // Create descriptor pool
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .storage_buffer, .descriptor_count = 4 },
        };

        const descriptor_pool = vkd.createDescriptorPool(device, &.{
            .max_sets = 1,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        }, null) catch |err| {
            std.debug.print("Failed to create descriptor pool: {any}\n", .{err});
            return error.DescriptorPoolCreationFailed;
        };

        errdefer vkd.destroyDescriptorPool(device, descriptor_pool, null);

        // Allocate descriptor set
        var descriptor_set: vk.DescriptorSet = undefined;
        vkd.allocateDescriptorSets(device, &.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
        }, @ptrCast(&descriptor_set)) catch |err| {
            std.debug.print("Failed to allocate descriptor sets: {any}\n", .{err});
            return error.DescriptorSetAllocationFailed;
        };

        // Update descriptor sets
        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{ .buffer = state_buffer.buffer, .offset = 0, .range = state_buffer.size },
            .{ .buffer = pattern_buffer.buffer, .offset = 0, .range = pattern_buffer.size },
            .{ .buffer = result_buffer.buffer, .offset = 0, .range = result_buffer.size },
            .{ .buffer = found_flag_buffer.buffer, .offset = 0, .range = found_flag_buffer.size },
        };

        // For storage buffers, image_info and texel_buffer_view are unused but require valid pointers
        const dummy_image_info: [1]vk.DescriptorImageInfo = undefined;
        const dummy_buffer_view: [1]vk.BufferView = undefined;

        const writes = [_]vk.WriteDescriptorSet{
            .{ .dst_set = descriptor_set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = &dummy_image_info, .p_buffer_info = @ptrCast(&buffer_infos[0]), .p_texel_buffer_view = &dummy_buffer_view },
            .{ .dst_set = descriptor_set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = &dummy_image_info, .p_buffer_info = @ptrCast(&buffer_infos[1]), .p_texel_buffer_view = &dummy_buffer_view },
            .{ .dst_set = descriptor_set, .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = &dummy_image_info, .p_buffer_info = @ptrCast(&buffer_infos[2]), .p_texel_buffer_view = &dummy_buffer_view },
            .{ .dst_set = descriptor_set, .dst_binding = 3, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = &dummy_image_info, .p_buffer_info = @ptrCast(&buffer_infos[3]), .p_texel_buffer_view = &dummy_buffer_view },
        };

        vkd.updateDescriptorSets(device, writes.len, &writes, 0, null);

        // Create command pool
        const command_pool = vkd.createCommandPool(device, &.{
            .queue_family_index = selected_queue_family,
            .flags = .{ .reset_command_buffer_bit = true },
        }, null) catch |err| {
            std.debug.print("Failed to create command pool: {any}\n", .{err});
            return error.CommandPoolCreationFailed;
        };

        errdefer vkd.destroyCommandPool(device, command_pool, null);

        // Allocate command buffer
        var command_buffer: vk.CommandBuffer = undefined;
        vkd.allocateCommandBuffers(device, &.{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer)) catch |err| {
            std.debug.print("Failed to allocate command buffer: {any}\n", .{err});
            return error.CommandBufferAllocationFailed;
        };

        // Create fence
        const fence = vkd.createFence(device, &.{
            .flags = .{},
        }, null) catch |err| {
            std.debug.print("Failed to create fence: {any}\n", .{err});
            return error.FenceCreationFailed;
        };

        errdefer vkd.destroyFence(device, fence, null);

        const default_threads: usize = 64;
        const threads_to_use = threads_per_group_override orelse default_threads;
        std.debug.print("Using workgroup size: {d}\n", .{threads_to_use});
        std.debug.print("Vulkan compute mode: Ed25519 + hex prefix match all on GPU\n", .{});

        const cpu_seed = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));

        return Self{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .compute_queue = compute_queue,
            .compute_queue_family = selected_queue_family,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline_layout = pipeline_layout,
            .compute_pipeline = compute_pipeline,
            .descriptor_pool = descriptor_pool,
            .descriptor_set = descriptor_set,
            .shader_module = shader_module,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .fence = fence,
            .state_buffer = state_buffer,
            .pattern_buffer = pattern_buffer,
            .result_buffer = result_buffer,
            .found_flag_buffer = found_flag_buffer,
            .pattern = pattern,
            .attempts = std.atomic.Value(u64).init(0),
            .start_time = std.time.milliTimestamp(),
            .allocator = allocator,
            .cpu_prng = std.Random.Xoshiro256.init(cpu_seed),
            .threads_per_group = threads_to_use,
            .p50_attempts = 0,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
        };
    }

    fn createBuffer(vkd: vk.DeviceWrapper, device: vk.Device, mem_props: *const vk.PhysicalDeviceMemoryProperties, size: vk.DeviceSize) !BufferAllocation {
        const buffer = vkd.createBuffer(device, &.{
            .size = size,
            .usage = .{ .storage_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        }, null) catch return error.BufferCreationFailed;

        errdefer vkd.destroyBuffer(device, buffer, null);

        const mem_reqs = vkd.getBufferMemoryRequirements(device, buffer);

        // Find memory type with host visible and coherent
        const mem_type_index = findMemoryType(
            mem_props,
            mem_reqs.memory_type_bits,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        ) orelse return error.NoSuitableMemoryType;

        const memory = vkd.allocateMemory(device, &.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type_index,
        }, null) catch return error.MemoryAllocationFailed;

        errdefer vkd.freeMemory(device, memory, null);

        vkd.bindBufferMemory(device, buffer, memory, 0) catch return error.MemoryBindFailed;

        const mapped = vkd.mapMemory(device, memory, 0, size, .{}) catch return error.MemoryMapFailed;

        return BufferAllocation{
            .buffer = buffer,
            .memory = memory,
            .size = size,
            .mapped = mapped,
        };
    }

    fn destroyBuffer(vkd: vk.DeviceWrapper, device: vk.Device, buf: BufferAllocation) void {
        if (buf.mapped != null) {
            vkd.unmapMemory(device, buf.memory);
        }
        vkd.destroyBuffer(device, buf.buffer, null);
        vkd.freeMemory(device, buf.memory, null);
    }

    fn findMemoryType(mem_props: *const vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) ?u32 {
        for (0..mem_props.memory_type_count) |i| {
            const idx: u5 = @intCast(i);
            if ((type_filter & (@as(u32, 1) << idx)) != 0) {
                const mem_type = mem_props.memory_types[i];
                if (mem_type.property_flags.host_visible_bit == properties.host_visible_bit and
                    mem_type.property_flags.host_coherent_bit == properties.host_coherent_bit)
                {
                    return @intCast(i);
                }
            }
        }
        return null;
    }

    pub fn setP50(self: *Self, p50: f64) void {
        self.p50_attempts = p50;
    }

    pub fn deinit(self: *Self) void {
        self.vkd.destroyFence(self.device, self.fence, null);
        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        destroyBuffer(self.vkd, self.device, self.found_flag_buffer);
        destroyBuffer(self.vkd, self.device, self.result_buffer);
        destroyBuffer(self.vkd, self.device, self.pattern_buffer);
        destroyBuffer(self.vkd, self.device, self.state_buffer);
        self.vkd.destroyPipeline(self.device, self.compute_pipeline, null);
        self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.vkd.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.vkd.destroyShaderModule(self.device, self.shader_module, null);
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroyInstance(self.instance, null);
    }

    fn runBatch(self: *Self) ?GpuResultBuffer {
        // Reset found flag
        const found_ptr: *u32 = @ptrCast(@alignCast(self.found_flag_buffer.mapped));
        found_ptr.* = 0;

        // Reset result
        const result_ptr: *GpuResultBuffer = @ptrCast(@alignCast(self.result_buffer.mapped));
        result_ptr.found = 0;

        // Update state with new RNG values
        const state_ptr: *[2]u64 = @ptrCast(@alignCast(self.state_buffer.mapped));
        state_ptr[0] = self.cpu_prng.next();
        state_ptr[1] = self.cpu_prng.next();

        // Reset command buffer
        self.vkd.resetCommandBuffer(self.command_buffer, .{}) catch return null;

        // Record command buffer
        self.vkd.beginCommandBuffer(self.command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        }) catch return null;

        self.vkd.cmdBindPipeline(self.command_buffer, .compute, self.compute_pipeline);
        self.vkd.cmdBindDescriptorSets(self.command_buffer, .compute, self.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);

        // Dispatch compute work
        const workgroups = @as(u32, @intCast(BATCH_SIZE / 64));
        self.vkd.cmdDispatch(self.command_buffer, workgroups, 1, 1);

        self.vkd.endCommandBuffer(self.command_buffer) catch return null;

        // Submit and wait
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self.command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };

        self.vkd.queueSubmit(self.compute_queue, 1, @ptrCast(&submit_info), self.fence) catch return null;
        _ = self.vkd.waitForFences(self.device, 1, @ptrCast(&self.fence), .true, std.math.maxInt(u64)) catch return null;
        self.vkd.resetFences(self.device, 1, @ptrCast(&self.fence)) catch return null;

        _ = self.attempts.fetchAdd(BATCH_SIZE, .monotonic);

        // Check result
        if (result_ptr.found != 0) {
            return result_ptr.*;
        }
        return null;
    }

    pub fn searchBatch(self: *Self, max_attempts: u64) !?FoundKey {
        const num_batches = max_attempts / BATCH_SIZE;
        if (num_batches == 0) return null;

        var batch: u64 = 0;
        while (batch < num_batches) {
            if (self.runBatch()) |result| {
                return FoundKey{
                    .public_key = result.public_key,
                    .private_key = result.private_key,
                    
                    .attempts = self.attempts.load(.acquire),
                };
            }

            batch += 1;
            if (batch % 10 == 0) {
                self.reportProgress();
            }
        }
        return null;
    }

    fn reportProgress(self: *Self) void {
        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const current_attempts = self.attempts.load(.acquire);
        const rate = if (elapsed_secs > 0)
            @as(f64, @floatFromInt(current_attempts)) / elapsed_secs
        else
            0;

        std.debug.print("\r[Vulkan] {d} keys, {d:.0} k/s, ", .{
            current_attempts,
            rate / 1000.0,
        });
        mod.formatTimeToP50(current_attempts, self.p50_attempts, rate);
        std.debug.print("        ", .{}); // Clear trailing chars
    }

    pub fn getRate(self: *Self) f64 {
        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const current_attempts = self.attempts.load(.acquire);
        return if (elapsed_secs > 0)
            @as(f64, @floatFromInt(current_attempts)) / elapsed_secs
        else
            0;
    }
};
