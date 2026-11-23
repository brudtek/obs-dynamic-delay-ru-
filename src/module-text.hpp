#pragma once

#include <obs-module.h>

#include <QString>

namespace dynamic_delay {

// Все подписи интерфейса берутся из data/locale/ru-RU.ini.
inline QString text(const char *key)
{
	return QString::fromUtf8(obs_module_text(key));
}

} // namespace dynamic_delay
