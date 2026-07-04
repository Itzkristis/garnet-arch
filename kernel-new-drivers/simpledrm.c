// SPDX-License-Identifier: GPL-2.0-only
/*
 * simpledrm - DRM driver for simple platform-provided framebuffers
 *
 * Backport of the v5.14 upstream driver to the garnet 5.10 downstream
 * tree, for the firmware (UEFI GOP / efifb) framebuffer. Differences
 * from upstream, forced by the 5.10 API surface:
 *
 *  - No drm_aperture / no kicking of efifb: we deliberately coexist
 *    with the built-in efifb (fbcon console stays on /dev/fb0; DRM
 *    clients render via /dev/dri/cardN into the same scanout memory).
 *    devm_ioremap_wc() does not reserve the region, so there is no
 *    resource conflict with efifb's claim.
 *  - No shadow-plane helpers (5.13+): the plane update vmaps the GEM
 *    object around the blit, like 5.10's in-tree tiny/cirrus.c.
 *  - No clock/regulator handling (only needed for DT simplefb on
 *    other SoCs; our firmware fb needs neither).
 *  - This 5.10 tree also lost the /chosen/simple-framebuffer platform
 *    device population, so the module can create its own platform
 *    device from module parameters:
 *      simpledrm.fb_base=0xb8000000 simpledrm.fb_width=1220 ...
 *    Defaults match the garnet UEFI GOP framebuffer, so a bare
 *    "modprobe simpledrm" works on the phone. simpledrm.auto_dev=0
 *    disables the self-created device (e.g. if a DT node exists).
 */

#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_data/simplefb.h>
#include <linux/platform_device.h>

#include <drm/drm_atomic_helper.h>
#include <drm/drm_atomic_state_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_damage_helper.h>
#include <drm/drm_device.h>
#include <drm/drm_drv.h>
#include <drm/drm_fb_helper.h>
#include <drm/drm_format_helper.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_gem_shmem_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_modeset_helper_vtables.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_simple_kms_helper.h>

#define DRIVER_NAME	"simpledrm"
#define DRIVER_DESC	"DRM driver for simple-framebuffer platform devices"
#define DRIVER_DATE	"20210419"
#define DRIVER_MAJOR	1
#define DRIVER_MINOR	0

/*
 * Assume a monitor resolution of 96 dpi to
 * get a somewhat reasonable screen size.
 */
#define RES_MM(d)	\
	(((d) * 254ul) / (10ul * 96ul))

#define SIMPLEDRM_MODE(hd, vd)	\
	DRM_SIMPLE_MODE(hd, vd, RES_MM(hd), RES_MM(vd))

/*
 * Helpers for simplefb
 */

struct simpledrm_format {
	const char *name;
	u32 fourcc;
};

/* names as used by the simple-framebuffer DT binding / simplefb */
static const struct simpledrm_format simpledrm_formats[] = {
	{ "r5g6b5",     DRM_FORMAT_RGB565 },
	{ "r8g8b8",     DRM_FORMAT_RGB888 },
	{ "x8r8g8b8",   DRM_FORMAT_XRGB8888 },
	{ "a8r8g8b8",   DRM_FORMAT_ARGB8888 },
	{ "a8b8g8r8",   DRM_FORMAT_ABGR8888 },
	{ "x2r10g10b10", DRM_FORMAT_XRGB2101010 },
	{ "a2r10g10b10", DRM_FORMAT_ARGB2101010 },
};

static int
simplefb_get_validated_int(struct drm_device *dev, const char *name,
			   uint32_t value)
{
	if (value > INT_MAX) {
		drm_err(dev, "simplefb: invalid framebuffer %s of %u\n",
			name, value);
		return -EINVAL;
	}
	return (int)value;
}

static int
simplefb_get_validated_int0(struct drm_device *dev, const char *name,
			    uint32_t value)
{
	if (!value) {
		drm_err(dev, "simplefb: invalid framebuffer %s of %u\n",
			name, value);
		return -EINVAL;
	}
	return simplefb_get_validated_int(dev, name, value);
}

static const struct drm_format_info *
simplefb_get_validated_format(struct drm_device *dev, const char *format_name)
{
	const struct simpledrm_format *fmt = simpledrm_formats;
	const struct simpledrm_format *end = fmt + ARRAY_SIZE(simpledrm_formats);
	const struct drm_format_info *info;

	if (!format_name) {
		drm_err(dev, "simplefb: missing framebuffer format\n");
		return ERR_PTR(-EINVAL);
	}

	while (fmt < end) {
		if (!strcmp(format_name, fmt->name)) {
			info = drm_format_info(fmt->fourcc);
			if (!info)
				return ERR_PTR(-EINVAL);
			return info;
		}
		++fmt;
	}

	drm_err(dev, "simplefb: unknown framebuffer format %s\n",
		format_name);

	return ERR_PTR(-EINVAL);
}

static int
simplefb_get_width_pd(struct drm_device *dev,
		      const struct simplefb_platform_data *pd)
{
	return simplefb_get_validated_int0(dev, "width", pd->width);
}

static int
simplefb_get_height_pd(struct drm_device *dev,
		       const struct simplefb_platform_data *pd)
{
	return simplefb_get_validated_int0(dev, "height", pd->height);
}

static int
simplefb_get_stride_pd(struct drm_device *dev,
		       const struct simplefb_platform_data *pd)
{
	return simplefb_get_validated_int(dev, "stride", pd->stride);
}

static const struct drm_format_info *
simplefb_get_format_pd(struct drm_device *dev,
		       const struct simplefb_platform_data *pd)
{
	return simplefb_get_validated_format(dev, pd->format);
}

static int
simplefb_read_u32_of(struct drm_device *dev, struct device_node *of_node,
		     const char *name, u32 *value)
{
	int ret = of_property_read_u32(of_node, name, value);

	if (ret)
		drm_err(dev, "simplefb: cannot parse framebuffer %s: error %d\n",
			name, ret);
	return ret;
}

static int
simplefb_read_string_of(struct drm_device *dev, struct device_node *of_node,
			const char *name, const char **value)
{
	int ret = of_property_read_string(of_node, name, value);

	if (ret)
		drm_err(dev, "simplefb: cannot parse framebuffer %s: error %d\n",
			name, ret);
	return ret;
}

static int
simplefb_get_width_of(struct drm_device *dev, struct device_node *of_node)
{
	u32 width;
	int ret = simplefb_read_u32_of(dev, of_node, "width", &width);

	if (ret)
		return ret;
	return simplefb_get_validated_int0(dev, "width", width);
}

static int
simplefb_get_height_of(struct drm_device *dev, struct device_node *of_node)
{
	u32 height;
	int ret = simplefb_read_u32_of(dev, of_node, "height", &height);

	if (ret)
		return ret;
	return simplefb_get_validated_int0(dev, "height", height);
}

static int
simplefb_get_stride_of(struct drm_device *dev, struct device_node *of_node)
{
	u32 stride;
	int ret = simplefb_read_u32_of(dev, of_node, "stride", &stride);

	if (ret)
		return ret;
	return simplefb_get_validated_int(dev, "stride", stride);
}

static const struct drm_format_info *
simplefb_get_format_of(struct drm_device *dev, struct device_node *of_node)
{
	const char *format;
	int ret = simplefb_read_string_of(dev, of_node, "format", &format);

	if (ret)
		return ERR_PTR(ret);
	return simplefb_get_validated_format(dev, format);
}

/*
 * Simple Framebuffer device
 */

struct simpledrm_device {
	struct drm_device dev;
	struct platform_device *pdev;

	/* simplefb settings */
	struct drm_display_mode mode;
	const struct drm_format_info *format;
	unsigned int pitch;

	/* memory management */
	struct resource *mem;
	void __iomem *screen_base;

	/* modesetting */
	uint32_t formats[8];
	size_t nformats;
	struct drm_connector connector;
	struct drm_simple_display_pipe pipe;
};

static struct simpledrm_device *simpledrm_device_of_dev(struct drm_device *dev)
{
	return container_of(dev, struct simpledrm_device, dev);
}

/*
 *  Simplefb settings
 */

static struct drm_display_mode simpledrm_mode(unsigned int width,
					      unsigned int height)
{
	struct drm_display_mode mode = { SIMPLEDRM_MODE(width, height) };

	mode.clock = mode.hdisplay * mode.vdisplay * 60 / 1000 /* kHz */;
	drm_mode_set_name(&mode);

	return mode;
}

static int simpledrm_device_init_fb(struct simpledrm_device *sdev)
{
	int width, height, stride;
	const struct drm_format_info *format;
	struct drm_device *dev = &sdev->dev;
	struct platform_device *pdev = sdev->pdev;
	const struct simplefb_platform_data *pd = dev_get_platdata(&pdev->dev);
	struct device_node *of_node = pdev->dev.of_node;

	if (pd) {
		width = simplefb_get_width_pd(dev, pd);
		if (width < 0)
			return width;
		height = simplefb_get_height_pd(dev, pd);
		if (height < 0)
			return height;
		stride = simplefb_get_stride_pd(dev, pd);
		if (stride < 0)
			return stride;
		format = simplefb_get_format_pd(dev, pd);
		if (IS_ERR(format))
			return PTR_ERR(format);
	} else if (of_node) {
		width = simplefb_get_width_of(dev, of_node);
		if (width < 0)
			return width;
		height = simplefb_get_height_of(dev, of_node);
		if (height < 0)
			return height;
		stride = simplefb_get_stride_of(dev, of_node);
		if (stride < 0)
			return stride;
		format = simplefb_get_format_of(dev, of_node);
		if (IS_ERR(format))
			return PTR_ERR(format);
	} else {
		drm_err(dev, "no simplefb configuration found\n");
		return -ENODEV;
	}
	if (!stride) {
		stride = format->cpp[0] * width;
		if (drm_WARN_ON(dev, !stride))
			return -EINVAL;
	}

	sdev->mode = simpledrm_mode(width, height);
	sdev->format = format;
	sdev->pitch = stride;

	drm_dbg_kms(dev, "display mode={" DRM_MODE_FMT "}\n",
		    DRM_MODE_ARG(&sdev->mode));
	drm_dbg_kms(dev,
		    "framebuffer format=%08x, size=%dx%d, stride=%d byte\n",
		    format->format, width, height, stride);

	/*
	 * 5.10's drm_fb_memcpy_dstclip() uses fb->pitches[0] for the
	 * destination as well; refuse configs where the hardware pitch
	 * differs from the pitch of a naturally-aligned framebuffer.
	 */
	if (sdev->pitch != drm_format_info_min_pitch(format, 0, width)) {
		drm_err(dev, "hw stride %u != fb pitch %llu, unsupported by 5.10 blit helpers\n",
			sdev->pitch,
			(unsigned long long)drm_format_info_min_pitch(format, 0, width));
		return -EINVAL;
	}

	return 0;
}

/*
 * Memory management
 */

static int simpledrm_device_init_mm(struct simpledrm_device *sdev)
{
	struct platform_device *pdev = sdev->pdev;
	struct resource *mem;
	void __iomem *screen_base;

	mem = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!mem)
		return -EINVAL;

	/*
	 * No request_mem_region()/aperture handling: efifb keeps its
	 * claim on the range and continues to provide the fbcon
	 * console. Both drivers just write pixels into the same
	 * firmware-scanout memory.
	 */
	screen_base = devm_ioremap_wc(&pdev->dev, mem->start,
				      resource_size(mem));
	if (!screen_base)
		return -ENOMEM;

	sdev->mem = mem;
	sdev->screen_base = screen_base;

	return 0;
}

/*
 * Modesetting
 */

static const uint32_t simpledrm_default_formats[] = {
	DRM_FORMAT_XRGB8888,
	DRM_FORMAT_ARGB8888,
	DRM_FORMAT_RGB565,
};

static const uint64_t simpledrm_format_modifiers[] = {
	DRM_FORMAT_MOD_LINEAR,
	DRM_FORMAT_MOD_INVALID
};

static int simpledrm_connector_helper_get_modes(struct drm_connector *connector)
{
	struct simpledrm_device *sdev = simpledrm_device_of_dev(connector->dev);
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev, &sdev->mode);
	if (!mode)
		return 0;

	if (mode->name[0] == '\0')
		drm_mode_set_name(mode);

	mode->type |= DRM_MODE_TYPE_PREFERRED;
	drm_mode_probed_add(connector, mode);

	if (mode->width_mm)
		connector->display_info.width_mm = mode->width_mm;
	if (mode->height_mm)
		connector->display_info.height_mm = mode->height_mm;

	return 1;
}

static const struct drm_connector_helper_funcs simpledrm_connector_helper_funcs = {
	.get_modes = simpledrm_connector_helper_get_modes,
};

static const struct drm_connector_funcs simpledrm_connector_funcs = {
	.reset = drm_atomic_helper_connector_reset,
	.fill_modes = drm_helper_probe_single_connector_modes,
	.destroy = drm_connector_cleanup,
	.atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
};

/*
 * Blitting with format conversion. 5.10 lacks the generic
 * drm_fb_blit_{rect_,}dstclip() dispatchers from 5.14's
 * drm_format_helper; provide a local equivalent over the helpers
 * that 5.10 does export.
 */
static int simpledrm_blit_rect(struct simpledrm_device *sdev,
			       void *vmap, struct drm_framebuffer *fb,
			       struct drm_rect *clip)
{
	uint32_t fb_format = fb->format->format;
	uint32_t dst_format = sdev->format->format;
	void __iomem *dst = sdev->screen_base;
	/* Clamp to both the fb and the hw scanout. 5.10's damage path can
	 * hand us a clip past the fb edge (seen live: full-width clip with
	 * y1 == vdisplay from a sway session -> memcpy_toio past the end of
	 * the ioremap = oops with the modeset lock held). The 5.10 blit
	 * helpers trust the clip completely, so distrust it here.
	 */
	struct drm_rect bounds = {
		.x1 = 0,
		.y1 = 0,
		.x2 = min_t(int, fb->width, sdev->mode.hdisplay),
		.y2 = min_t(int, fb->height, sdev->mode.vdisplay),
	};

	if (!drm_rect_intersect(clip, &bounds))
		return 0;

	if (dst_format == fb_format ||
	    (dst_format == DRM_FORMAT_XRGB8888 && fb_format == DRM_FORMAT_ARGB8888) ||
	    (dst_format == DRM_FORMAT_ARGB8888 && fb_format == DRM_FORMAT_XRGB8888)) {
		/* NOT drm_fb_memcpy_dstclip(): 5.10's version advances the
		 * destination by fb->pitches[0]. Client buffers with a pitch
		 * different from the hw stride (sway/pixman allocates padded
		 * strides) then drift off the end of the scanout mapping —
		 * second live oops of the day. Walk the lines with separate
		 * pitches for src (fb) and dst (hw).
		 */
		unsigned int cpp = fb->format->cpp[0];
		size_t len = drm_rect_width(clip) * cpp;
		unsigned int y;
		void *src = vmap + clip->y1 * fb->pitches[0] + clip->x1 * cpp;
		void __iomem *dst_line = dst + clip->y1 * sdev->pitch +
					 clip->x1 * cpp;

		for (y = clip->y1; y < clip->y2; y++) {
			memcpy_toio(dst_line, src, len);
			src += fb->pitches[0];
			dst_line += sdev->pitch;
		}
		return 0;
	}
	if (dst_format == DRM_FORMAT_RGB565 && fb_format == DRM_FORMAT_XRGB8888) {
		drm_fb_xrgb8888_to_rgb565_dstclip(dst, sdev->pitch,
						  vmap, fb, clip, false);
		return 0;
	}
	if (dst_format == DRM_FORMAT_RGB888 && fb_format == DRM_FORMAT_XRGB8888) {
		drm_fb_xrgb8888_to_rgb888_dstclip(dst, sdev->pitch,
						  vmap, fb, clip);
		return 0;
	}

	drm_err_once(&sdev->dev, "no blit helper %08x -> %08x\n",
		     fb_format, dst_format);
	return -EINVAL;
}

/* vmap the whole GEM object around the blit, like 5.10's tiny/cirrus.c */
static void simpledrm_blit_fb(struct simpledrm_device *sdev,
			      struct drm_framebuffer *fb,
			      struct drm_rect *clip)
{
	struct drm_gem_object *obj = drm_gem_fb_get_obj(fb, 0);
	void *vmap;

	if (!obj)
		return;
	vmap = drm_gem_shmem_vmap(obj);
	if (IS_ERR(vmap))
		return;
	simpledrm_blit_rect(sdev, vmap, fb, clip);
	drm_gem_shmem_vunmap(obj, vmap);
}

static enum drm_mode_status
simpledrm_simple_display_pipe_mode_valid(struct drm_simple_display_pipe *pipe,
					 const struct drm_display_mode *mode)
{
	struct simpledrm_device *sdev = simpledrm_device_of_dev(pipe->crtc.dev);

	if (mode->hdisplay != sdev->mode.hdisplay &&
	    mode->vdisplay != sdev->mode.vdisplay)
		return MODE_ONE_SIZE;
	else if (mode->hdisplay != sdev->mode.hdisplay)
		return MODE_ONE_WIDTH;
	else if (mode->vdisplay != sdev->mode.vdisplay)
		return MODE_ONE_HEIGHT;

	return MODE_OK;
}

static void
simpledrm_simple_display_pipe_enable(struct drm_simple_display_pipe *pipe,
				     struct drm_crtc_state *crtc_state,
				     struct drm_plane_state *plane_state)
{
	struct simpledrm_device *sdev = simpledrm_device_of_dev(pipe->crtc.dev);
	struct drm_framebuffer *fb = plane_state->fb;
	struct drm_device *dev = &sdev->dev;
	struct drm_rect clip;
	int idx;

	if (!fb)
		return;

	if (!drm_dev_enter(dev, &idx))
		return;

	clip.x1 = 0;
	clip.y1 = 0;
	clip.x2 = fb->width;
	clip.y2 = fb->height;
	simpledrm_blit_fb(sdev, fb, &clip);

	drm_dev_exit(idx);
}

static void
simpledrm_simple_display_pipe_disable(struct drm_simple_display_pipe *pipe)
{
	struct simpledrm_device *sdev = simpledrm_device_of_dev(pipe->crtc.dev);
	struct drm_device *dev = &sdev->dev;
	int idx;

	if (!drm_dev_enter(dev, &idx))
		return;

	/* Clear screen to black if disabled */
	memset_io(sdev->screen_base, 0, sdev->pitch * sdev->mode.vdisplay);

	drm_dev_exit(idx);
}

static void
simpledrm_simple_display_pipe_update(struct drm_simple_display_pipe *pipe,
				     struct drm_plane_state *old_plane_state)
{
	struct simpledrm_device *sdev = simpledrm_device_of_dev(pipe->crtc.dev);
	struct drm_plane_state *plane_state = pipe->plane.state;
	struct drm_framebuffer *fb = plane_state->fb;
	struct drm_device *dev = &sdev->dev;
	struct drm_rect clip;
	int idx;

	if (!fb)
		return;

	if (!drm_atomic_helper_damage_merged(old_plane_state, plane_state, &clip))
		return;

	if (!drm_dev_enter(dev, &idx))
		return;

	simpledrm_blit_fb(sdev, fb, &clip);

	drm_dev_exit(idx);
}

static const struct drm_simple_display_pipe_funcs
simpledrm_simple_display_pipe_funcs = {
	.mode_valid = simpledrm_simple_display_pipe_mode_valid,
	.enable = simpledrm_simple_display_pipe_enable,
	.disable = simpledrm_simple_display_pipe_disable,
	.update = simpledrm_simple_display_pipe_update,
	.prepare_fb = drm_gem_fb_simple_display_pipe_prepare_fb,
};

static const struct drm_mode_config_funcs simpledrm_mode_config_funcs = {
	.fb_create = drm_gem_fb_create_with_dirty,
	.atomic_check = drm_atomic_helper_check,
	.atomic_commit = drm_atomic_helper_commit,
};

static const uint32_t *simpledrm_device_formats(struct simpledrm_device *sdev,
						size_t *nformats_out)
{
	struct drm_device *dev = &sdev->dev;
	size_t i;

	if (sdev->nformats)
		goto out; /* don't rebuild list on recurring calls */

	/* native format goes first */
	sdev->formats[0] = sdev->format->format;
	sdev->nformats = 1;

	/* default formats go second */
	for (i = 0; i < ARRAY_SIZE(simpledrm_default_formats); ++i) {
		if (simpledrm_default_formats[i] == sdev->format->format)
			continue; /* native format already went first */
		sdev->formats[sdev->nformats] = simpledrm_default_formats[i];
		sdev->nformats++;
	}

	/*
	 * TODO: The simpledrm driver converts framebuffers to the native
	 * format when copying them to device memory. If there are more
	 * formats listed than supported by the driver, the native format
	 * is not supported by the conversion helpers. Therefore *only*
	 * support the native format and add a conversion helper ASAP.
	 */
	if (drm_WARN_ONCE(dev, i != sdev->nformats,
			  "format conversion helpers required for %08x",
			  sdev->format->format)) {
		sdev->nformats = 1;
	}

out:
	*nformats_out = sdev->nformats;
	return sdev->formats;
}

static int simpledrm_device_init_modeset(struct simpledrm_device *sdev)
{
	struct drm_device *dev = &sdev->dev;
	struct drm_display_mode *mode = &sdev->mode;
	struct drm_connector *connector = &sdev->connector;
	struct drm_simple_display_pipe *pipe = &sdev->pipe;
	const uint32_t *formats;
	size_t nformats;
	int ret;

	ret = drmm_mode_config_init(dev);
	if (ret)
		return ret;

	dev->mode_config.min_width = mode->hdisplay;
	dev->mode_config.max_width = mode->hdisplay;
	dev->mode_config.min_height = mode->vdisplay;
	dev->mode_config.max_height = mode->vdisplay;
	dev->mode_config.prefer_shadow_fbdev = true;
	dev->mode_config.preferred_depth = sdev->format->cpp[0] * 8;
	dev->mode_config.funcs = &simpledrm_mode_config_funcs;

	ret = drm_connector_init(dev, connector, &simpledrm_connector_funcs,
				 DRM_MODE_CONNECTOR_Unknown);
	if (ret)
		return ret;
	drm_connector_helper_add(connector, &simpledrm_connector_helper_funcs);

	formats = simpledrm_device_formats(sdev, &nformats);

	ret = drm_simple_display_pipe_init(dev, pipe, &simpledrm_simple_display_pipe_funcs,
					   formats, nformats, simpledrm_format_modifiers,
					   connector);
	if (ret)
		return ret;

	drm_mode_config_reset(dev);

	return 0;
}

/*
 * Init / Cleanup
 */

static struct simpledrm_device *
simpledrm_device_create(struct drm_driver *drv, struct platform_device *pdev)
{
	struct simpledrm_device *sdev;
	int ret;

	sdev = devm_drm_dev_alloc(&pdev->dev, drv, struct simpledrm_device,
				  dev);
	if (IS_ERR(sdev))
		return ERR_CAST(sdev);
	sdev->pdev = pdev;
	platform_set_drvdata(pdev, sdev);

	ret = simpledrm_device_init_fb(sdev);
	if (ret)
		return ERR_PTR(ret);
	ret = simpledrm_device_init_mm(sdev);
	if (ret)
		return ERR_PTR(ret);
	ret = simpledrm_device_init_modeset(sdev);
	if (ret)
		return ERR_PTR(ret);

	return sdev;
}

/*
 * DRM driver
 */

DEFINE_DRM_GEM_FOPS(simpledrm_fops);

static struct drm_driver simpledrm_driver = {
	DRM_GEM_SHMEM_DRIVER_OPS,
	.name			= DRIVER_NAME,
	.desc			= DRIVER_DESC,
	.date			= DRIVER_DATE,
	.major			= DRIVER_MAJOR,
	.minor			= DRIVER_MINOR,
	.driver_features	= DRIVER_ATOMIC | DRIVER_GEM | DRIVER_MODESET,
	.fops			= &simpledrm_fops,
};

/*
 * Platform driver
 */

static int simpledrm_probe(struct platform_device *pdev)
{
	struct simpledrm_device *sdev;
	struct drm_device *dev;
	int ret;

	sdev = simpledrm_device_create(&simpledrm_driver, pdev);
	if (IS_ERR(sdev))
		return PTR_ERR(sdev);
	dev = &sdev->dev;

	ret = drm_dev_register(dev, 0);
	if (ret)
		return ret;

	drm_fbdev_generic_setup(dev, 0);

	return 0;
}

static int simpledrm_remove(struct platform_device *pdev)
{
	struct simpledrm_device *sdev = platform_get_drvdata(pdev);
	struct drm_device *dev = &sdev->dev;

	drm_dev_unplug(dev);

	return 0;
}

static const struct of_device_id simpledrm_of_match_table[] = {
	{ .compatible = "simple-framebuffer", },
	{ },
};
MODULE_DEVICE_TABLE(of, simpledrm_of_match_table);

static struct platform_driver simpledrm_platform_driver = {
	.driver = {
		.name = "simple-framebuffer", /* connect to sysfb */
		.of_match_table = simpledrm_of_match_table,
	},
	.probe = simpledrm_probe,
	.remove = simpledrm_remove,
};

/*
 * Self-created platform device (garnet): this downstream 5.10 tree
 * does not populate /chosen simple-framebuffer DT nodes and has no
 * sysfb, so optionally create the platform device here. Defaults
 * describe the garnet UEFI GOP framebuffer.
 */

static bool auto_dev = true;
module_param(auto_dev, bool, 0444);
MODULE_PARM_DESC(auto_dev, "create a simple-framebuffer device from fb_* params (default: on)");

static unsigned long fb_base = 0xb8000000;
module_param(fb_base, ulong, 0444);
MODULE_PARM_DESC(fb_base, "physical framebuffer base address");

static unsigned int fb_width = 1220;
module_param(fb_width, uint, 0444);
MODULE_PARM_DESC(fb_width, "framebuffer width in pixels");

static unsigned int fb_height = 2712;
module_param(fb_height, uint, 0444);
MODULE_PARM_DESC(fb_height, "framebuffer height in pixels");

static unsigned int fb_stride; /* 0 = width * cpp */
module_param(fb_stride, uint, 0444);
MODULE_PARM_DESC(fb_stride, "framebuffer stride in bytes (0 = width*cpp)");

static char *fb_format = "a8r8g8b8";
module_param(fb_format, charp, 0444);
MODULE_PARM_DESC(fb_format, "framebuffer format (simplefb name, e.g. a8r8g8b8)");

static struct platform_device *simpledrm_auto_pdev;

static int __init simpledrm_auto_dev_create(void)
{
	struct simplefb_platform_data pd = {
		.width = fb_width,
		.height = fb_height,
		.stride = fb_stride ? fb_stride : fb_width * 4,
		.format = fb_format,
	};
	struct resource res = DEFINE_RES_MEM(fb_base, pd.stride * pd.height);
	struct platform_device *pdev;

	pdev = platform_device_register_resndata(NULL, "simple-framebuffer",
						 -1, &res, 1,
						 &pd, sizeof(pd));
	if (IS_ERR(pdev))
		return PTR_ERR(pdev);

	simpledrm_auto_pdev = pdev;
	return 0;
}

static int __init simpledrm_init(void)
{
	int ret;

	ret = platform_driver_register(&simpledrm_platform_driver);
	if (ret)
		return ret;

	if (auto_dev) {
		ret = simpledrm_auto_dev_create();
		if (ret)
			pr_warn("simpledrm: auto device creation failed: %d\n",
				ret);
	}

	return 0;
}

static void __exit simpledrm_exit(void)
{
	if (simpledrm_auto_pdev)
		platform_device_unregister(simpledrm_auto_pdev);
	platform_driver_unregister(&simpledrm_platform_driver);
}

module_init(simpledrm_init);
module_exit(simpledrm_exit);

MODULE_DESCRIPTION(DRIVER_DESC);
MODULE_LICENSE("GPL v2");
