// SPDX-License-Identifier: GPL-2.0
// Minimal extcon provider for garnet bring-up: binds the EUD DT node
// (qcom,msm-eud) in place of the real EUD driver and permanently reports
// VBUS present, so dwc3-msm starts peripheral mode through its designed
// extcon path. The extcon is registered on a child platform device named
// "fake_vbus.0": dwc3-msm special-cases extcon names containing "eud"
// (spoof-connect logic), and extcon names are copied from the parent
// device name. The child's of_node still points at the EUD node so
// extcon_get_edev_by_phandle() finds us. Remove once real cable
// detection (typec/PMIC) is brought up.
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/platform_device.h>
#include <linux/extcon-provider.h>

static struct extcon_dev *fake_vbus_edev;

static const unsigned int fake_vbus_cables[] = {
	EXTCON_USB,
	EXTCON_USB_HOST,
	EXTCON_NONE,
};

static int fake_vbus_probe(struct platform_device *pdev)
{
	struct platform_device *child;
	struct extcon_dev *edev;
	int ret;

	child = platform_device_register_simple("fake_vbus", 0, NULL, 0);
	if (IS_ERR(child))
		return PTR_ERR(child);

	child->dev.of_node = of_node_get(pdev->dev.of_node);

	edev = devm_extcon_dev_allocate(&child->dev, fake_vbus_cables);
	if (IS_ERR(edev)) {
		ret = PTR_ERR(edev);
		goto err_child;
	}

	ret = devm_extcon_dev_register(&child->dev, edev);
	if (ret)
		goto err_child;

	platform_set_drvdata(pdev, child);
	fake_vbus_edev = edev;
	extcon_set_state_sync(edev, EXTCON_USB, true);
	dev_info(&pdev->dev, "fake-vbus (as %s): USB peripheral attached\n",
		 dev_name(&child->dev));
	return 0;

err_child:
	platform_device_unregister(child);
	return ret;
}

static const struct of_device_id fake_vbus_of_match[] = {
	{ .compatible = "qcom,msm-eud" },
	{ }
};
MODULE_DEVICE_TABLE(of, fake_vbus_of_match);

static struct platform_driver fake_vbus_driver = {
	.probe = fake_vbus_probe,
	.driver = {
		.name = "extcon-fake-vbus",
		.of_match_table = fake_vbus_of_match,
	},
};
module_platform_driver(fake_vbus_driver);

/* runtime role switch: echo peripheral|host|none > /sys/module/extcon_fake_vbus/parameters/mode */
static int fake_vbus_mode_set(const char *val, const struct kernel_param *kp)
{
	if (!fake_vbus_edev)
		return -ENODEV;
	if (sysfs_streq(val, "peripheral")) {
		extcon_set_state_sync(fake_vbus_edev, EXTCON_USB_HOST, false);
		extcon_set_state_sync(fake_vbus_edev, EXTCON_USB, true);
	} else if (sysfs_streq(val, "host")) {
		extcon_set_state_sync(fake_vbus_edev, EXTCON_USB, false);
		extcon_set_state_sync(fake_vbus_edev, EXTCON_USB_HOST, true);
	} else if (sysfs_streq(val, "none")) {
		extcon_set_state_sync(fake_vbus_edev, EXTCON_USB, false);
		extcon_set_state_sync(fake_vbus_edev, EXTCON_USB_HOST, false);
	} else {
		return -EINVAL;
	}
	pr_info("fake-vbus: mode -> %s\n", val);
	return 0;
}

static int fake_vbus_mode_get(char *buf, const struct kernel_param *kp)
{
	if (!fake_vbus_edev)
		return scnprintf(buf, PAGE_SIZE, "unloaded");
	if (extcon_get_state(fake_vbus_edev, EXTCON_USB_HOST))
		return scnprintf(buf, PAGE_SIZE, "host");
	if (extcon_get_state(fake_vbus_edev, EXTCON_USB))
		return scnprintf(buf, PAGE_SIZE, "peripheral");
	return scnprintf(buf, PAGE_SIZE, "none");
}

static const struct kernel_param_ops fake_vbus_mode_ops = {
	.set = fake_vbus_mode_set,
	.get = fake_vbus_mode_get,
};
module_param_cb(mode, &fake_vbus_mode_ops, NULL, 0644);

MODULE_DESCRIPTION("Fake VBUS extcon for garnet USB bring-up");
MODULE_LICENSE("GPL v2");
