#include "delay-dock.hpp"

#include "audience-preview.hpp"
#include "delay-controller.hpp"
#include "module-text.hpp"

#include <QComboBox>
#include <QFormLayout>
#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QLocale>
#include <QProgressBar>
#include <QResizeEvent>
#include <QScrollArea>
#include <QScrollBar>
#include <QStyle>
#include <QPushButton>
#include <QSignalBlocker>
#include <QSlider>
#include <QSpinBox>
#include <QStandardItemModel>
#include <QToolButton>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>

namespace dynamic_delay {

namespace {

// Подпись строки формы: переносится на вторую строку, если панель узкая,
// а полный текст всегда виден во всплывающей подсказке.
QLabel *form_label(const QString &caption, QWidget *parent, const QString &tooltip = {})
{
	auto *label = new QLabel(caption, parent);
	label->setWordWrap(true);
	label->setToolTip(tooltip.isEmpty() ? caption : tooltip);
	return label;
}

// Выпадающий список не растягивает панель длинным пунктом: ширина задаётся
// раскладкой, а выбранный пункт целиком виден в подсказке.
void make_compact(QComboBox *combo)
{
	combo->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
	combo->setMinimumContentsLength(8);
	combo->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
}

void sync_combo_tooltip(QComboBox *combo, const QString &base)
{
	const QString current = combo->currentText();
	combo->setToolTip(base.isEmpty() ? current : current + QStringLiteral("\n\n") + base);
}

QFormLayout *make_form()
{
	auto *form = new QFormLayout;
	form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
	form->setRowWrapPolicy(QFormLayout::WrapLongRows);
	form->setLabelAlignment(Qt::AlignLeft | Qt::AlignVCenter);
	return form;
}

} // namespace

DelayDock::DelayDock(DelayController &controller, QWidget *parent) : QWidget(parent), controller_(controller)
{
	build_ui();
	connect(&controller_, &DelayController::snapshot_changed, this, &DelayDock::apply_snapshot);
	connect(&controller_, &DelayController::settings_changed, this, &DelayDock::apply_settings);
	connect(&controller_, &DelayController::scenes_changed, this, [this] { rebuild_scenes(); });
	connect(&controller_, &DelayController::audio_sources_changed, this, [this] { rebuild_audio_sources(); });
	connect(&controller_, &DelayController::audio_preflight_changed, audioWarning_, &QLabel::setText);
	rebuild_scenes();
	rebuild_audio_sources();
	apply_settings(controller_.settings());
	audioWarning_->setText(controller_.audio_preflight());
	apply_snapshot(controller_.snapshot());
}

DelayDock::~DelayDock() = default;

void DelayDock::build_ui()
{
	setMinimumWidth(220);

	// Содержимое лежит в прокручиваемой области без рамки: при малой высоте
	// панели или крупном масштабе Windows элементы не сплющиваются.
	auto *outer = new QVBoxLayout(this);
	outer->setContentsMargins(0, 0, 0, 0);
	auto *scroll = new QScrollArea(this);
	scroll->setFrameShape(QFrame::NoFrame);
	scroll->setWidgetResizable(true);
	scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
	scroll->setObjectName(QStringLiteral("delayDockScroll"));
	scroll->setStyleSheet(QStringLiteral("QScrollArea#delayDockScroll, QScrollArea#delayDockScroll > QWidget > "
					     "QWidget#delayDockContent { background: transparent; }"));
	auto *content = new QWidget(scroll);
	content_ = content;
	content->setObjectName(QStringLiteral("delayDockContent"));
	scroll->setWidget(content);
	scroll->viewport()->setAutoFillBackground(false);
	content->setAutoFillBackground(false);
	outer->addWidget(scroll);

	auto *root = new QVBoxLayout(content);
	root->setContentsMargins(12, 12, 12, 12);
	root->setSpacing(10);

	auto *statusRow = new QHBoxLayout;
	statusDot_ = new QLabel(QStringLiteral("●"), this);
	statusDot_->setAccessibleName(text("Dock.StatusAccessible"));
	statusText_ = new QLabel(this);
	statusText_->setWordWrap(true);
	QFont statusFont = statusText_->font();
	statusFont.setBold(true);
	statusText_->setFont(statusFont);
	statusRow->addWidget(statusDot_);
	statusRow->addWidget(statusText_, 1);
	root->addLayout(statusRow);

	detailText_ = new QLabel(this);
	detailText_->setWordWrap(true);
	root->addWidget(detailText_);

	auto *delayLabel = new QLabel(text("Delay.Title"), this);
	QFont sectionFont = delayLabel->font();
	sectionFont.setBold(true);
	delayLabel->setFont(sectionFont);
	root->addWidget(delayLabel);

	auto *delayRow = new QHBoxLayout;
	delaySlider_ = new QSlider(Qt::Horizontal, this);
	delaySlider_->setRange(1, 300);
	delaySlider_->setSingleStep(1);
	delaySlider_->setPageStep(5);
	delaySlider_->setToolTip(text("Delay.Tooltip"));
	delaySpin_ = new QSpinBox(this);
	delaySpin_->setRange(1, 300);
	delaySpin_->setSuffix(text("Delay.Suffix"));
	delaySpin_->setMinimumWidth(82);
	delaySpin_->setToolTip(text("Delay.Tooltip"));
	delayRow->addWidget(delaySlider_, 1);
	delayRow->addWidget(delaySpin_);
	root->addLayout(delayRow);

	connect(delaySlider_, &QSlider::valueChanged, delaySpin_, &QSpinBox::setValue);
	connect(delaySpin_, qOverload<int>(&QSpinBox::valueChanged), delaySlider_, &QSlider::setValue);
	connect(delaySpin_, qOverload<int>(&QSpinBox::valueChanged), &controller_, &DelayController::set_delay_seconds);

	auto *form = make_form();
	holdForm_ = form;
	sceneCombo_ = new QComboBox(this);
	make_compact(sceneCombo_);
	transitionCombo_ = new QComboBox(this);
	make_compact(transitionCombo_);
	transitionCombo_->addItem(text("Transition.Cut"), static_cast<int>(TransitionStyle::Cut));
	transitionCombo_->addItem(text("Transition.Fade"), static_cast<int>(TransitionStyle::FadeThroughBlack));
	if (auto *model = qobject_cast<QStandardItemModel *>(transitionCombo_->model())) {
		if (QStandardItem *fade = model->item(1)) {
			fade->setFlags(fade->flags() & ~Qt::ItemIsEnabled);
			fade->setToolTip(text("Transition.Tooltip"));
		}
	}
	form->addRow(form_label(text("Hold.Scene"), this, text("Hold.SceneTooltip")), sceneCombo_);
	form->addRow(form_label(text("Transition.Label"), this, text("Transition.Tooltip")), transitionCombo_);
	root->addLayout(form);

	connect(sceneCombo_, &QComboBox::currentIndexChanged, this, [this](int index) {
		sync_combo_tooltip(sceneCombo_, text("Hold.SceneTooltip"));
		if (!applying_ && index >= 0)
			controller_.set_hold_scene(sceneCombo_->itemData(index).toString());
	});
	connect(transitionCombo_, &QComboBox::currentIndexChanged, this, [this](int index) {
		sync_combo_tooltip(transitionCombo_, text("Transition.Tooltip"));
		if (!applying_ && index >= 0)
			controller_.set_transition_style(transitionCombo_->itemData(index).toInt());
	});
	sync_combo_tooltip(transitionCombo_, text("Transition.Tooltip"));

	auto *audioLabel = new QLabel(text("Audio.Title"), this);
	audioLabel->setFont(sectionFont);
	audioLabel->setWordWrap(true);
	root->addWidget(audioLabel);

	auto *audioForm = make_form();
	audioForm_ = audioForm;
	audioModeCombo_ = new QComboBox(this);
	make_compact(audioModeCombo_);
	audioModeCombo_->addItem(text("Audio.SceneMix"), static_cast<int>(HoldAudioMode::SceneMix));
	audioModeCombo_->addItem(text("Audio.Dedicated"), static_cast<int>(HoldAudioMode::DedicatedSource));
	audioModeCombo_->addItem(text("Audio.Reserved"), static_cast<int>(HoldAudioMode::ReservedTrack));
	audioModeCombo_->addItem(text("Audio.Silence"), static_cast<int>(HoldAudioMode::Silence));
	audioSourceCombo_ = new QComboBox(this);
	make_compact(audioSourceCombo_);
	reservedTrackCombo_ = new QComboBox(this);
	make_compact(reservedTrackCombo_);
	for (int track = 1; track <= MAX_AUDIO_MIXES; ++track)
		reservedTrackCombo_->addItem(text("Audio.TrackItem").arg(track), track);
	audioSourceLabel_ = form_label(text("Audio.Source"), this, text("Audio.SourceTooltip"));
	reservedTrackLabel_ = form_label(text("Audio.Track"), this, text("Audio.TrackTooltip"));
	audioForm->addRow(form_label(text("Audio.Mode"), this, text("Audio.ModeTooltip")), audioModeCombo_);
	audioForm->addRow(audioSourceLabel_, audioSourceCombo_);
	audioForm->addRow(reservedTrackLabel_, reservedTrackCombo_);
	root->addLayout(audioForm);
	sync_combo_tooltip(audioModeCombo_, text("Audio.ModeTooltip"));
	sync_combo_tooltip(reservedTrackCombo_, text("Audio.TrackTooltip"));

	audioWarning_ = new QLabel(this);
	audioWarning_->setWordWrap(true);
	audioWarning_->setAccessibleName(text("Audio.PreflightAccessible"));
	audioWarning_->setStyleSheet(
		QStringLiteral("QLabel { border-left: 3px solid #f3b33d; padding: 4px 6px; }"));
	root->addWidget(audioWarning_);

	connect(audioModeCombo_, &QComboBox::currentIndexChanged, this, [this](int index) {
		sync_combo_tooltip(audioModeCombo_, text("Audio.ModeTooltip"));
		if (!applying_ && index >= 0)
			controller_.set_hold_audio_mode(audioModeCombo_->itemData(index).toInt());
		update_audio_controls();
	});
	connect(audioSourceCombo_, &QComboBox::currentIndexChanged, this, [this](int index) {
		sync_combo_tooltip(audioSourceCombo_, text("Audio.SourceTooltip"));
		if (!applying_ && index >= 0)
			controller_.set_hold_audio_source(audioSourceCombo_->itemData(index).toString());
	});
	connect(reservedTrackCombo_, &QComboBox::currentIndexChanged, this, [this](int index) {
		sync_combo_tooltip(reservedTrackCombo_, text("Audio.TrackTooltip"));
		if (!applying_ && index >= 0)
			controller_.set_reserved_audio_track(reservedTrackCombo_->itemData(index).toInt());
	});

	auto *memoryFrame = new QFrame(this);
	memoryFrame->setFrameShape(QFrame::StyledPanel);
	auto *memoryLayout = new QFormLayout(memoryFrame);
	memoryLayout->setRowWrapPolicy(QFormLayout::WrapLongRows);
	memoryEstimate_ = new QLabel(this);
	memoryEstimate_->setWordWrap(true);
	memoryActual_ = new QLabel(this);
	memoryActual_->setWordWrap(true);
	memoryLayout->addRow(form_label(text("Memory.Estimate"), this, text("Memory.EstimateTooltip")),
			     memoryEstimate_);
	memoryLayout->addRow(form_label(text("Memory.Buffer"), this, text("Memory.BufferTooltip")), memoryActual_);
	root->addWidget(memoryFrame);

	progress_ = new QProgressBar(this);
	progress_->setRange(0, 1000);
	progress_->setTextVisible(true);
	progress_->setAlignment(Qt::AlignCenter);
	root->addWidget(progress_);

	toggleButton_ = new QPushButton(this);
	toggleButton_->setMinimumHeight(36);
	connect(toggleButton_, &QPushButton::clicked, &controller_, &DelayController::toggle_delay);
	root->addWidget(toggleButton_);

	previewToggle_ = new QToolButton(this);
	previewToggle_->setText(text("Preview.Toggle"));
	previewToggle_->setToolTip(text("Preview.Toggle"));
	previewToggle_->setCheckable(true);
	previewToggle_->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
	previewToggle_->setArrowType(Qt::RightArrow);
	connect(previewToggle_, &QToolButton::toggled, this, &DelayDock::set_preview_visible);
	root->addWidget(previewToggle_);

	preview_ = new AudiencePreviewWidget(controller_, this);
	preview_->setVisible(false);
	root->addWidget(preview_);
	root->addStretch(1);
	update_secondary_colors();
	update_minimum_width();
}

// Панель нельзя сузить сильнее, чем помещается самое широкое содержимое
// (подписи над полями, кнопка предпросмотра): иначе элементы обрезались бы справа.
void DelayDock::update_minimum_width()
{
	if (!content_ || !holdForm_ || !audioForm_)
		return;
	const auto holdPolicy = holdForm_->rowWrapPolicy();
	const auto audioPolicy = audioForm_->rowWrapPolicy();
	holdForm_->setRowWrapPolicy(QFormLayout::WrapAllRows);
	audioForm_->setRowWrapPolicy(QFormLayout::WrapAllRows);
	content_->layout()->activate();
	const int contentWidth = content_->minimumSizeHint().width();
	holdForm_->setRowWrapPolicy(holdPolicy);
	audioForm_->setRowWrapPolicy(audioPolicy);
	const int scrollbar = style()->pixelMetric(QStyle::PM_ScrollBarExtent, nullptr, this);
	setMinimumWidth(std::max(220, contentWidth + scrollbar + 2));
}

// Пояснения набираются приглушённым, но читаемым цветом: смесь цвета текста
// и фона темы. В исходном плагине был palette(mid), почти невидимый на тёмной теме.
void DelayDock::update_secondary_colors()
{
	if (!detailText_ || !audioWarning_)
		return;
	const QColor fg = palette().color(QPalette::WindowText);
	const QColor bg = palette().color(QPalette::Window);
	const QColor muted((fg.red() * 7 + bg.red() * 3) / 10, (fg.green() * 7 + bg.green() * 3) / 10,
			   (fg.blue() * 7 + bg.blue() * 3) / 10);
	for (QLabel *label : {detailText_, audioWarning_}) {
		QPalette labelPalette = label->palette();
		labelPalette.setColor(QPalette::WindowText, muted);
		label->setPalette(labelPalette);
	}
}

void DelayDock::changeEvent(QEvent *event)
{
	QWidget::changeEvent(event);
	if (event->type() == QEvent::PaletteChange || event->type() == QEvent::StyleChange)
		update_secondary_colors();
	if (event->type() == QEvent::FontChange || event->type() == QEvent::StyleChange)
		update_minimum_width();
}

void DelayDock::resizeEvent(QResizeEvent *event)
{
	QWidget::resizeEvent(event);
	update_form_wrapping();
}

// Если панель слишком узкая, чтобы подпись и самый длинный пункт списка
// поместились в одну строку, подписи переносятся над полями. Порог зависит
// только от шрифта и текстов, а не от текущей раскладки, поэтому не мигает.
void DelayDock::update_form_wrapping()
{
	if (!holdForm_ || !audioForm_)
		return;
	const QFontMetrics metrics(font());
	const int margins = 24;
	const int comboChrome = 48;
	const auto needed = [&](const QStringList &labels, const QStringList &items) {
		int label = 0;
		for (const QString &caption : labels)
			label = std::max(label, metrics.horizontalAdvance(caption));
		int item = 0;
		for (const QString &caption : items)
			item = std::max(item, metrics.horizontalAdvance(caption));
		return margins + label + std::max(holdForm_->horizontalSpacing(), 6) + 12 + item + comboChrome;
	};
	const int holdNeeded = needed({text("Hold.Scene"), text("Transition.Label")}, {text("Transition.Cut")});
	const int audioNeeded = needed({text("Audio.Mode"), text("Audio.Track")},
				       {text("Audio.SceneMix"), text("Audio.SourceNone")});
	// Оба блока переносятся вместе, чтобы колонки подписей не расходились.
	const bool stacked = width() < std::max(holdNeeded, audioNeeded);
	for (QFormLayout *form : {holdForm_, audioForm_}) {
		const auto policy = stacked ? QFormLayout::WrapAllRows : QFormLayout::WrapLongRows;
		if (form->rowWrapPolicy() != policy)
			form->setRowWrapPolicy(policy);
		// Над полем подписи хватает всей ширины, перенос слов нужен только сбоку.
		for (int row = 0; row < form->rowCount(); ++row) {
			QLayoutItem *item = form->itemAt(row, QFormLayout::LabelRole);
			if (auto *label = item ? qobject_cast<QLabel *>(item->widget()) : nullptr)
				label->setWordWrap(!stacked);
		}
	}
}

QString DelayDock::bytes_text(const std::size_t bytes)
{
	constexpr double MiB = 1024.0 * 1024.0;
	constexpr double GiB = 1024.0 * MiB;
	const QLocale russian(QLocale::Russian, QLocale::Russia);
	if (bytes >= static_cast<std::size_t>(GiB))
		return text("Memory.GiB").arg(russian.toString(static_cast<double>(bytes) / GiB, 'f', 2));
	return text("Memory.MiB").arg(russian.toString(static_cast<double>(bytes) / MiB, 'f', 1));
}

QString DelayDock::state_text(const DelayState state)
{
	switch (state) {
	case DelayState::Bypass:
		return text("State.Live");
	case DelayState::Preparing:
		return text("State.Preparing");
	case DelayState::Filling:
		return text("State.Filling");
	case DelayState::Delayed:
		return text("State.Delayed");
	case DelayState::ReturningLive:
		return text("State.ReturningLive");
	case DelayState::Error:
		return text("State.Error");
	}
	return text("State.Unknown");
}

void DelayDock::apply_snapshot(const DelaySnapshot &snapshot)
{
	const bool active = controller_.requested_active();
	// Задержка запрошена, но ни трансляция, ни запись ещё не запущены.
	const bool armed = active && snapshot.state == DelayState::Preparing && snapshot.activeOutputs == 0;
	const QString stateCaption = armed ? text("State.Armed") : state_text(snapshot.state);

	statusText_->setText(stateCaption);
	const QString detail = QString::fromStdString(snapshot.detail);
	detailText_->setText(detail);
	detailText_->setVisible(!detail.isEmpty() && detail != stateCaption);
	if (snapshot.estimateAvailable)
		memoryEstimate_->setText(bytes_text(snapshot.estimatedBytes));
	else if (snapshot.activeOutputs != 0)
		memoryEstimate_->setText(text("Memory.Measuring"));
	else
		memoryEstimate_->setText(text("Memory.NoOutput"));
	memoryActual_->setText(bytes_text(snapshot.bufferedBytes));
	progress_->setValue(static_cast<int>(std::clamp(snapshot.progress, 0.0, 1.0) * 1000.0));
	if (snapshot.state == DelayState::Filling)
		progress_->setFormat(text("Progress.Filling"));
	else if (snapshot.state == DelayState::Delayed && snapshot.effectiveSeconds > 0.0)
		progress_->setFormat(
			text("Progress.Delayed").arg(static_cast<int>(std::lround(snapshot.effectiveSeconds))));
	else
		progress_->setFormat(stateCaption);
	progress_->setToolTip(detail.isEmpty() ? stateCaption : detail);

	QString color = QStringLiteral("#36c56f");
	if (snapshot.state == DelayState::Preparing || snapshot.state == DelayState::Filling ||
	    snapshot.state == DelayState::ReturningLive)
		color = QStringLiteral("#f3b33d");
	else if (snapshot.state == DelayState::Delayed)
		color = QStringLiteral("#4b9cff");
	else if (snapshot.state == DelayState::Error)
		color = QStringLiteral("#ef5350");
	const int colorState = static_cast<int>(snapshot.state);
	if (colorState != lastStatusColor_) {
		statusDot_->setStyleSheet(QStringLiteral("color: %1;").arg(color));
		lastStatusColor_ = colorState;
	}

	QString buttonCaption = text("Button.Add");
	if (active) {
		if (armed)
			buttonCaption = text("Button.CancelArmed");
		else if (snapshot.state == DelayState::Preparing || snapshot.state == DelayState::Filling)
			buttonCaption = text("Button.CancelFill");
		else
			buttonCaption = text("Button.Remove");
	}
	toggleButton_->setText(buttonCaption);
	toggleButton_->setToolTip(buttonCaption);
	toggleButton_->setProperty("delayActive", active);
	configurationEnabled_ = snapshot.state == DelayState::Bypass || snapshot.state == DelayState::Delayed ||
				snapshot.state == DelayState::Error || armed;
	delaySlider_->setEnabled(configurationEnabled_);
	delaySpin_->setEnabled(configurationEnabled_);
	sceneCombo_->setEnabled(configurationEnabled_);
	transitionCombo_->setEnabled(configurationEnabled_);
	audioModeCombo_->setEnabled(configurationEnabled_);
	update_audio_controls();
}

void DelayDock::apply_settings(const DelaySettings &settings)
{
	applying_ = true;
	delaySlider_->setValue(static_cast<int>(settings.delaySeconds));
	delaySpin_->setValue(static_cast<int>(settings.delaySeconds));
	const int transitionIndex = transitionCombo_->findData(static_cast<int>(settings.transition));
	if (transitionIndex >= 0)
		transitionCombo_->setCurrentIndex(transitionIndex);
	const int sceneIndex = sceneCombo_->findData(QString::fromStdString(settings.holdSceneUuid));
	if (sceneIndex >= 0)
		sceneCombo_->setCurrentIndex(sceneIndex);
	const int audioModeIndex = audioModeCombo_->findData(static_cast<int>(settings.holdAudioMode));
	if (audioModeIndex >= 0)
		audioModeCombo_->setCurrentIndex(audioModeIndex);
	const int audioSourceIndex = audioSourceCombo_->findData(QString::fromStdString(settings.holdAudioSourceUuid));
	if (audioSourceIndex >= 0)
		audioSourceCombo_->setCurrentIndex(audioSourceIndex);
	else if (settings.holdAudioSourceUuid.empty())
		audioSourceCombo_->setCurrentIndex(0);
	else {
		const QString missingUuid = QString::fromStdString(settings.holdAudioSourceUuid);
		audioSourceCombo_->addItem(text("Audio.SourceMissing").arg(missingUuid), missingUuid);
		audioSourceCombo_->setCurrentIndex(audioSourceCombo_->count() - 1);
	}
	const int reservedTrackIndex = reservedTrackCombo_->findData(static_cast<int>(settings.reservedAudioTrack));
	if (reservedTrackIndex >= 0)
		reservedTrackCombo_->setCurrentIndex(reservedTrackIndex);
	previewToggle_->setChecked(settings.previewExpanded);
	applying_ = false;
	update_audio_controls();
}

void DelayDock::rebuild_audio_sources()
{
	const DelaySettings current = controller_.settings();
	applying_ = true;
	audioSourceCombo_->clear();
	audioSourceCombo_->addItem(text("Audio.SourceNone"), QString{});
	for (const AudioSourceChoice &source : controller_.audio_sources())
		audioSourceCombo_->addItem(source.name, source.uuid);
	const QString selectedUuid = QString::fromStdString(current.holdAudioSourceUuid);
	int index = audioSourceCombo_->findData(selectedUuid);
	if (index < 0 && !selectedUuid.isEmpty()) {
		audioSourceCombo_->addItem(text("Audio.SourceMissing").arg(selectedUuid), selectedUuid);
		index = audioSourceCombo_->count() - 1;
	}
	audioSourceCombo_->setCurrentIndex(index >= 0 ? index : 0);
	sync_combo_tooltip(audioSourceCombo_, text("Audio.SourceTooltip"));
	applying_ = false;
	update_audio_controls();
}

void DelayDock::update_audio_controls()
{
	if (!audioModeCombo_)
		return;
	const auto mode = static_cast<HoldAudioMode>(audioModeCombo_->currentData().toInt());
	const bool sourceRelevant = mode == HoldAudioMode::SceneMix || mode == HoldAudioMode::DedicatedSource;
	const bool trackRelevant = mode == HoldAudioMode::ReservedTrack;
	audioSourceLabel_->setEnabled(configurationEnabled_ && sourceRelevant);
	audioSourceCombo_->setEnabled(configurationEnabled_ && sourceRelevant);
	reservedTrackLabel_->setEnabled(configurationEnabled_ && trackRelevant);
	reservedTrackCombo_->setEnabled(configurationEnabled_ && trackRelevant);
}

void DelayDock::rebuild_scenes()
{
	const DelaySettings current = controller_.settings();
	applying_ = true;
	sceneCombo_->clear();
	for (const SceneChoice &scene : controller_.scenes())
		sceneCombo_->addItem(scene.name, scene.uuid);
	const int index = sceneCombo_->findData(QString::fromStdString(current.holdSceneUuid));
	if (index >= 0)
		sceneCombo_->setCurrentIndex(index);
	sync_combo_tooltip(sceneCombo_, text("Hold.SceneTooltip"));
	applying_ = false;
}

void DelayDock::set_preview_visible(const bool visible)
{
	previewToggle_->setArrowType(visible ? Qt::DownArrow : Qt::RightArrow);
	preview_->setVisible(visible);
	preview_->set_enabled(visible);
	if (!applying_)
		controller_.set_preview_expanded(visible);
}

} // namespace dynamic_delay
