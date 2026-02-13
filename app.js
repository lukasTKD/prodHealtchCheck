// =============================================================================
// app.js - Server Health Monitor + Status Infrastruktury
// =============================================================================

let serverData = null;
let infraData = null;
let currentGroup = 'DCI';

// Zakładki infrastrukturalne
const infraTabs = {
    ClustersWindows:  { renderer: renderClusters },
    UdzialySieciowe:  { renderer: renderFileShares },
    InstancjeSQL:     { renderer: renderSQLInstances },
    KolejkiMQ:        { renderer: renderMQQueues },
    PrzelaczeniaRol:  { renderer: renderRoleSwitches }
};

// Zakładka logów
const logsTabs = ['LogiEventLog'];

function isInfraTab(group) {
    return group in infraTabs;
}

function isLogsTab(group) {
    return logsTabs.includes(group);
}

// =============================================================================
// LOADING DATA
// =============================================================================

async function loadData() {
    try {
        if (isLogsTab(currentGroup)) {
            // Zakładka logów - renderuj formularz, nie ładuj danych automatycznie
            serverData = null;
            infraData = null;
            LogsViewer.render();
            return;
        } else if (isInfraTab(currentGroup)) {
            const response = await fetch('api.aspx?type=infra&group=' + currentGroup + '&t=' + Date.now());
            const text = await response.text();
            try {
                infraData = JSON.parse(text);
            } catch (parseErr) {
                infraData = null;
                document.getElementById('serverGrid').innerHTML =
                    '<div class="error-message">Brak danych lub blad formatu odpowiedzi (HTTP ' + response.status + ')</div>';
                return;
            }
            serverData = null;
            if (infraData && infraData.error) {
                document.getElementById('serverGrid').innerHTML =
                    '<div class="error-message">' + infraData.error + '</div>';
                return;
            }
            updateInfraUI();
        } else {
            const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
            const text = await response.text();
            try {
                serverData = JSON.parse(text);
            } catch (parseErr) {
                serverData = null;
                document.getElementById('serverGrid').innerHTML =
                    '<div class="error-message">Brak danych lub blad formatu odpowiedzi (HTTP ' + response.status + ')</div>';
                return;
            }
            infraData = null;
            if (serverData && serverData.error) {
                document.getElementById('serverGrid').innerHTML =
                    '<div class="error-message">' + serverData.error + '</div>';
                return;
            }
            updateUI();
        }
    } catch (error) {
        document.getElementById('serverGrid').innerHTML =
            '<div class="error-message">Blad ladowania danych: ' + error.message + '</div>';
    }
}

function switchTab(group) {
    currentGroup = group;
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelector('.tab[data-group="' + group + '"]').classList.add('active');
    document.getElementById('serverGrid').innerHTML = '<div class="loading">Ladowanie danych...</div>';
    document.getElementById('serverGrid').classList.remove('sql-grid');
    document.getElementById('tabSearchBar').innerHTML = '';

    // Resetuj filtr krytycznych
    criticalFilterActive = false;
    document.querySelector('.stat-card.warning').classList.remove('active');

    // Dla zakładki logów - ukryj pasek statystyk wyszukiwania
    if (isLogsTab(group)) {
        document.getElementById('tabSearchBar').style.display = 'none';
    } else {
        document.getElementById('tabSearchBar').style.display = '';
    }

    loadData();
}

function getProgressClass(percent) {
    if (percent >= 90) return 'red';
    if (percent >= 70) return 'yellow';
    return 'green';
}

function getServiceStateClass(state) {
    if (!state) return '';
    const s = state.toLowerCase();
    if (s === 'running') return 'running';
    if (s === 'stopped') return 'stopped';
    return '';
}

function updateUI() {
    if (!serverData) return;
    
    // Dodaj pasek wyszukiwania dla zakładek kondycji serwerów
    const searchBar = document.getElementById('tabSearchBar');
    searchBar.innerHTML = '<input type="text" class="tab-search-input" placeholder="Szukaj serwera..." onkeyup="filterServers()">';
    
    document.getElementById('lastUpdate').textContent = serverData.LastUpdate;
    document.getElementById('duration').textContent = serverData.CollectionDuration;
    document.getElementById('totalServers').textContent = serverData.TotalServers;
    document.getElementById('successServers').textContent = serverData.SuccessCount;
    document.getElementById('failedServers').textContent = serverData.FailedCount;

    let criticalCount = 0;
    serverData.Servers.forEach(s => {
        if (s.CPU >= 90 || (s.RAM && s.RAM.PercentUsed >= 90)) criticalCount++;
    });
    document.getElementById('criticalServers').textContent = criticalCount;
    renderServers(serverData.Servers);
}

function renderServers(servers) {
    const grid = document.getElementById('serverGrid');
    if (!servers || servers.length === 0) {
        grid.innerHTML = '<div class="loading">Brak danych</div>';
        return;
    }

    grid.innerHTML = servers.map(server => {
        const hasError = server.Error;
        const isCritical = server.CPU >= 90 || (server.RAM && server.RAM.PercentUsed >= 90);
        const cardClass = hasError ? 'error' : (isCritical ? 'warning' : '');

        if (hasError) {
            return `
                <div class="server-card error" data-server="${server.ServerName}">
                    <div class="server-name">
                        ${server.ServerName}
                        ${server.DMZGroup ? `<span class="dmz-group">${server.DMZGroup}</span>` : ''}
                        <span class="time">${server.CollectedAt || ''}</span>
                    </div>
                    <div class="error-message">${server.Error}</div>
                </div>
            `;
        }

        const cpuPercent = server.CPU || 0;
        const ramPercent = server.RAM?.PercentUsed || 0;

        return `
            <div class="server-card ${cardClass}" data-server="${server.ServerName}">
                <div class="server-name">
                    ${server.ServerName}
                    ${server.DMZGroup ? `<span class="dmz-group">${server.DMZGroup}</span>` : ''}
                    <span class="time">${server.CollectedAt || ''}</span>
                </div>

                <div class="metrics-grid">
                    <div class="metric">
                        <div class="metric-label">CPU</div>
                        <div class="metric-value">${cpuPercent}%</div>
                        <div class="progress-bar">
                            <div class="progress-fill ${getProgressClass(cpuPercent)}" style="width: ${cpuPercent}%"></div>
                        </div>
                    </div>
                    <div class="metric">
                        <div class="metric-label">RAM</div>
                        <div class="metric-value">${ramPercent}% (${server.RAM?.UsedGB || 0}/${server.RAM?.TotalGB || 0} GB)</div>
                        <div class="progress-bar">
                            <div class="progress-fill ${getProgressClass(ramPercent)}" style="width: ${ramPercent}%"></div>
                        </div>
                    </div>
                </div>

                <div class="section">
                    <div class="section-title">Dyski</div>
                    <div class="disk-list">
                        ${(server.Disks || []).map(d => `
                            <div class="disk-item">
                                <div class="drive">${d.Drive}</div>
                                <div class="space">${d.FreeGB}/${d.TotalGB} GB wolne</div>
                                <div class="progress-bar">
                                    <div class="progress-fill ${getProgressClass(100 - d.PercentFree)}" style="width: ${100 - d.PercentFree}%"></div>
                                </div>
                            </div>
                        `).join('')}
                    </div>
                </div>

                <div class="metrics-grid" style="margin-top: 12px;">
                    <div class="section">
                        <div class="section-title collapsible" onclick="toggleSection(this)">Top 3 CPU</div>
                        <div class="collapsible-content">
                            ${(server.TopCPUServices || []).map(p => `
                                <div class="top-process">
                                    <span>${p.Name}</span>
                                    <span>${p.CPUPercent}%</span>
                                </div>
                            `).join('')}
                        </div>
                    </div>
                    <div class="section">
                        <div class="section-title collapsible" onclick="toggleSection(this)">Top 3 RAM</div>
                        <div class="collapsible-content">
                            ${(server.TopRAMServices || []).map(p => `
                                <div class="top-process">
                                    <span>${p.Name}</span>
                                    <span>${p.MemoryMB} MB</span>
                                </div>
                            `).join('')}
                        </div>
                    </div>
                </div>

                <div class="section">
                    <div class="section-title collapsible" onclick="toggleSection(this)">
                        Serwisy D:\\ (${(server.DServices || []).length})
                    </div>
                    <div class="collapsible-content">
                        <div class="service-list">
                            ${(server.DServices || []).map(s => `
                                <span class="service-badge ${getServiceStateClass(s.State)}" title="${s.DisplayName}">
                                    ${s.Name}: ${s.State}
                                </span>
                            `).join('')}
                            ${(server.DServices || []).length === 0 ? '<span style="color:#888">Brak</span>' : ''}
                        </div>
                    </div>
                </div>

                <div class="metrics-grid" style="margin-top: 12px;">
                    <div class="section">
                        <div class="section-title">Trellix</div>
                        <div class="service-list">
                            ${(server.TrellixStatus || []).map(t => `
                                <span class="service-badge ${getServiceStateClass(t.State)}" title="${t.Name}">
                                    ${t.State}
                                </span>
                            `).join('')}
                        </div>
                    </div>
                    <div class="section">
                        <div class="section-title">Firewall</div>
                        <div class="firewall-list">
                            <div>Domain: <span class="status-badge ${server.Firewall?.Domain ? 'status-on' : 'status-off'}">${server.Firewall?.Domain ? 'ON' : 'OFF'}</span></div>
                            <div>Private: <span class="status-badge ${server.Firewall?.Private ? 'status-on' : 'status-off'}">${server.Firewall?.Private ? 'ON' : 'OFF'}</span></div>
                            <div>Public: <span class="status-badge ${server.Firewall?.Public ? 'status-on' : 'status-off'}">${server.Firewall?.Public ? 'ON' : 'OFF'}</span></div>
                        </div>
                    </div>
                </div>

                ${server.IIS?.Installed ? `
                <div class="section iis-section">
                    <div class="section-title collapsible" onclick="toggleSection(this)">
                        IIS <span class="service-badge ${getServiceStateClass(server.IIS.ServiceState)}">${server.IIS.ServiceState}</span>
                    </div>
                    <div class="collapsible-content">
                        ${server.IIS.Error ? `<div class="error-message">${server.IIS.Error}</div>` : ''}
                        <div class="iis-grid">
                            <div class="iis-column">
                                <div class="iis-subtitle">Application Pools (${(server.IIS.AppPools || []).length})</div>
                                <div class="iis-list">
                                    ${(server.IIS.AppPools || []).map(pool => `
                                        <div class="iis-item">
                                            <span class="iis-name">${pool.Name}</span>
                                            <span class="status-badge ${pool.State === 'Started' ? 'status-on' : 'status-off'}">${pool.State}</span>
                                        </div>
                                    `).join('')}
                                    ${(server.IIS.AppPools || []).length === 0 ? '<span style="color:#888">Brak</span>' : ''}
                                </div>
                            </div>
                            <div class="iis-column">
                                <div class="iis-subtitle">Sites (${(server.IIS.Sites || []).length})</div>
                                <div class="iis-list">
                                    ${(server.IIS.Sites || []).map(site => `
                                        <div class="iis-item">
                                            <span class="iis-name" title="${site.Bindings || ''}">${site.Name}</span>
                                            <span class="status-badge ${site.State === 'Started' ? 'status-on' : 'status-off'}">${site.State}</span>
                                        </div>
                                    `).join('')}
                                    ${(server.IIS.Sites || []).length === 0 ? '<span style="color:#888">Brak</span>' : ''}
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                ` : ''}

                ${server.PendingUpdates?.Enabled ? `
                <div class="section sccm-section ${server.PendingUpdates.Count > 0 ? 'has-updates' : ''}">
                    <div class="section-title collapsible" onclick="toggleSection(this)">
                        SCCM Updates
                        <span class="update-count ${server.PendingUpdates.Count > 0 ? 'pending' : 'ok'}">
                            ${server.PendingUpdates.Count}
                        </span>
                    </div>
                    <div class="collapsible-content">
                        ${server.PendingUpdates.Error ? `<div class="error-message">${server.PendingUpdates.Error}</div>` : ''}
                        ${server.PendingUpdates.Count === 0 ? '<div style="color:#2e7d32;font-size:0.9em;">Brak oczekujacych aktualizacji</div>' : ''}
                        <div class="updates-list">
                            ${(server.PendingUpdates.Updates || []).map(upd => `
                                <div class="update-item">
                                    <span class="update-name" title="${upd.Name}">${upd.ArticleID ? 'KB' + upd.ArticleID : upd.Name}</span>
                                </div>
                            `).join('')}
                        </div>
                    </div>
                </div>
                ` : ''}
            </div>
        `;
    }).join('');
}

function toggleSection(element) {
    element.classList.toggle('collapsed');
    element.nextElementSibling.classList.toggle('hidden');
}

function filterServers() {
    const searchInput = document.querySelector('#tabSearchBar .tab-search-input');
    if (!searchInput) return;
    
    const search = searchInput.value.toLowerCase().trim();
    
    // Wyczyść wszystkie podświetlenia
    clearHighlights();
    
    if (!search) {
        // Jeśli puste wyszukiwanie - pokaż wszystko
        document.querySelectorAll('.server-card, .cluster-container, .mq-container').forEach(el => {
            el.style.display = '';
            el.classList.remove('highlight-card');
        });
        document.querySelectorAll('.infra-table tbody tr, .mq-table tbody tr').forEach(row => {
            row.style.display = '';
            row.classList.remove('highlight-row');
        });
        return;
    }
    
    if (isInfraTab(currentGroup)) {
        if (currentGroup === 'UdzialySieciowe' || currentGroup === 'InstancjeSQL') {
            // Karty z wewnętrznymi tabelami - szukaj w tabelach i nagłówkach
            document.querySelectorAll('.server-card').forEach(card => {
                const rows = card.querySelectorAll('.infra-table tbody tr');
                let hasMatch = false;
                
                // Sprawdź nagłówek karty (nazwa serwera)
                const serverName = card.querySelector('.server-name');
                if (serverName && serverName.textContent.toLowerCase().includes(search)) {
                    hasMatch = true;
                    card.classList.add('highlight-card');
                }
                
                // Sprawdź każdy wiersz tabeli
                rows.forEach(row => {
                    const rowText = row.textContent.toLowerCase();
                    if (rowText.includes(search)) {
                        row.classList.add('highlight-row');
                        hasMatch = true;
                        highlightTextInElement(row, search);
                    }
                });
                
                card.style.display = hasMatch ? '' : 'none';
                
                // Jeśli znaleziono - rozwiń zwinięte sekcje
                if (hasMatch) {
                    card.querySelectorAll('.collapsible-content.hidden').forEach(content => {
                        content.classList.remove('hidden');
                        if (content.previousElementSibling) {
                            content.previousElementSibling.classList.remove('collapsed');
                        }
                    });
                }
            });
        } else if (currentGroup === 'KolejkiMQ') {
            // Tabela MQ - filtruj i podświetlaj wiersze
            let visibleRows = 0;
            document.querySelectorAll('.mq-table tbody tr').forEach(row => {
                const rowText = row.textContent.toLowerCase();
                if (rowText.includes(search)) {
                    row.style.display = '';
                    row.classList.add('highlight-row');
                    highlightTextInElement(row, search);
                    visibleRows++;
                } else {
                    row.style.display = 'none';
                    row.classList.remove('highlight-row');
                }
            });
            const mqContainer = document.querySelector('.mq-container');
            if (mqContainer) {
                mqContainer.style.display = visibleRows > 0 ? '' : 'none';
            }
        } else if (currentGroup === 'ClustersWindows') {
            // Karty klastrów - szukaj w całej zawartości
            document.querySelectorAll('.cluster-container').forEach(card => {
                const cardText = card.textContent.toLowerCase();
                if (cardText.includes(search)) {
                    card.style.display = '';
                    card.classList.add('highlight-card');
                    // Podświetl w rolach i nagłówkach węzłów
                    card.querySelectorAll('.role-item, .node-header, .node-info, .cluster-header').forEach(el => {
                        if (el.textContent.toLowerCase().includes(search)) {
                            highlightTextInElement(el, search);
                        }
                    });
                } else {
                    card.style.display = 'none';
                    card.classList.remove('highlight-card');
                }
            });
        }
    } else {
        // Zakładki kondycji serwerów - szukaj w kartach
        document.querySelectorAll('.server-card').forEach(card => {
            const cardText = card.textContent.toLowerCase();
            if (cardText.includes(search)) {
                card.style.display = '';
                card.classList.add('highlight-card');
            } else {
                card.style.display = 'none';
                card.classList.remove('highlight-card');
            }
        });
    }
}

// Podświetlanie tekstu w elemencie
function highlightTextInElement(element, search) {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null, false);
    const textNodes = [];
    while (walker.nextNode()) {
        textNodes.push(walker.currentNode);
    }
    
    textNodes.forEach(node => {
        const text = node.textContent;
        const lowerText = text.toLowerCase();
        const idx = lowerText.indexOf(search);
        if (idx >= 0) {
            const before = text.substring(0, idx);
            const match = text.substring(idx, idx + search.length);
            const after = text.substring(idx + search.length);
            
            const fragment = document.createDocumentFragment();
            if (before) fragment.appendChild(document.createTextNode(before));
            
            const mark = document.createElement('mark');
            mark.className = 'search-highlight';
            mark.textContent = match;
            fragment.appendChild(mark);
            
            if (after) fragment.appendChild(document.createTextNode(after));
            
            node.parentNode.replaceChild(fragment, node);
        }
    });
}

// Czyszczenie podświetleń
function clearHighlights() {
    document.querySelectorAll('mark.search-highlight').forEach(mark => {
        const parent = mark.parentNode;
        if (parent) {
            parent.replaceChild(document.createTextNode(mark.textContent), mark);
            parent.normalize();
        }
    });
    document.querySelectorAll('.highlight-row').forEach(el => el.classList.remove('highlight-row'));
    document.querySelectorAll('.highlight-card').forEach(el => el.classList.remove('highlight-card'));
}

let criticalFilterActive = false;
function filterCritical() {
    // Filtr krytycznych działa tylko na zakładkach kondycji serwerów
    if (isInfraTab(currentGroup)) return;

    criticalFilterActive = !criticalFilterActive;
    document.querySelector('.stat-card.warning').classList.toggle('active', criticalFilterActive);

    if (criticalFilterActive) {
        document.querySelectorAll('.server-card').forEach(card => {
            card.style.display = card.classList.contains('warning') ? 'block' : 'none';
        });
    } else {
        document.querySelectorAll('.server-card').forEach(card => {
            card.style.display = 'block';
        });
        document.getElementById('searchInput').value = '';
    }
}

// =============================================================================
// INFRASTRUCTURE UI
// =============================================================================

function updateInfraUI() {
    if (!infraData) return;

    document.getElementById('lastUpdate').textContent = infraData.LastUpdate || '-';
    document.getElementById('duration').textContent = infraData.CollectionDuration || '-';

    if (currentGroup === 'ClustersWindows') {
        const loadedFilesCount = (infraData.LoadedFiles || []).length;
        document.getElementById('totalServers').textContent = infraData.TotalClusters || 0;
        document.getElementById('successServers').textContent = infraData.OnlineCount || 0;
        document.getElementById('failedServers').textContent = infraData.FailedCount || 0;
        document.getElementById('criticalServers').textContent = loadedFilesCount > 0 ? loadedFilesCount + ' plikow' : '-';
    } else if (currentGroup === 'UdzialySieciowe') {
        const totalShares = (infraData.FileServers || []).reduce((sum, s) => sum + (s.ShareCount || 0), 0);
        document.getElementById('totalServers').textContent = infraData.TotalServers || 0;
        document.getElementById('successServers').textContent = totalShares;
        document.getElementById('failedServers').textContent = (infraData.FileServers || []).filter(s => s.Error).length;
        document.getElementById('criticalServers').textContent = '-';
    } else if (currentGroup === 'InstancjeSQL') {
        const totalDBs = (infraData.Instances || []).reduce((sum, s) => sum + (s.DatabaseCount || 0), 0);
        const failedCount = (infraData.Instances || []).filter(s => s.Error).length;
        document.getElementById('totalServers').textContent = infraData.TotalInstances || 0;
        document.getElementById('successServers').textContent = totalDBs + ' baz';
        document.getElementById('failedServers').textContent = failedCount;
        document.getElementById('criticalServers').textContent = '-';
    } else if (currentGroup === 'KolejkiMQ') {
        document.getElementById('totalServers').textContent = infraData.TotalServers || 0;
        const totalQM = (infraData.Servers || []).reduce((sum, s) => sum + (s.QueueManagers || []).length, 0);
        document.getElementById('successServers').textContent = totalQM;
        document.getElementById('failedServers').textContent = (infraData.Servers || []).filter(s => s.Error).length;
        document.getElementById('criticalServers').textContent = '-';
    } else if (currentGroup === 'PrzelaczeniaRol') {
        document.getElementById('totalServers').textContent = infraData.TotalEvents || 0;
        document.getElementById('successServers').textContent = infraData.DaysBack || 30;
        document.getElementById('failedServers').textContent = '-';
        document.getElementById('criticalServers').textContent = '-';
    }

    infraTabs[currentGroup].renderer(infraData);
}

// --- KLASTRY WINDOWS ---
function renderClusters(data) {
    const searchBar = document.getElementById('tabSearchBar');
    searchBar.innerHTML = '<input type="text" class="tab-search-input" placeholder="Szukaj w klastrach..." onkeyup="filterServers()">';
    
    const grid = document.getElementById('serverGrid');
    const clusters = data.Clusters || [];

    if (clusters.length === 0) {
        grid.innerHTML = '<div class="loading">Brak danych o klastrach</div>';
        return;
    }

    grid.innerHTML = clusters.map(cluster => {
        const hasError = cluster.Error;
        const clusterTypeClass = cluster.ClusterType ? `cluster-${cluster.ClusterType.toLowerCase()}` : '';
        
        if (hasError) {
            return `
                <div class="cluster-container" data-server="${cluster.ClusterName}">
                    <div class="cluster-header ${clusterTypeClass}">
                        ${cluster.ClusterName}
                        <span class="cluster-type">${cluster.ClusterType || 'Unknown'}</span>
                    </div>
                    <div class="cluster-error">${cluster.Error}</div>
                </div>`;
        }

        const nodes = cluster.Nodes || [];
        const roles = cluster.Roles || [];

        // Grupuj role według węzła właściciela
        const rolesByNode = {};
        nodes.forEach(node => {
            rolesByNode[node.Name] = roles.filter(r => r.OwnerNode === node.Name);
        });

        return `
            <div class="cluster-container" data-server="${cluster.ClusterName}">
                <div class="cluster-header ${clusterTypeClass}">
                    ${cluster.ClusterName}
                    <span class="cluster-type">${cluster.ClusterType || 'Unknown'}</span>
                </div>
                <div class="cluster-nodes">
                    ${nodes.map(node => {
                        const nodeRoles = rolesByNode[node.Name] || [];
                        const isUp = node.State === 'Up';
                        
                        return `
                            <div class="node-column">
                                <div class="node-header">
                                    <div class="node-status-indicator ${isUp ? 'up' : 'down'}"></div>
                                    <div>${node.Name}</div>
                                </div>
                                <div class="node-info">
                                    <div><strong>Status:</strong> ${node.State}</div>
                                    <div><strong>IP:</strong> ${node.IPAddresses || 'N/A'}</div>
                                </div>
                                <div class="node-roles">
                                    ${nodeRoles.length === 0 ? '<div style="padding:15px;text-align:center;color:#999;font-size:0.85em;">Brak ról</div>' : 
                                        nodeRoles.map(role => {
                                            const isOnline = role.State === 'Online';
                                            const isMQ = role.Name && role.Name.match(/QM/i);
                                            const roleClass = isMQ ? 'role-mq' : (isOnline ? 'role-online' : 'role-offline');
                                            const portInfo = role.Port ? ` PORT(${role.Port})` : '';

                                            return `
                                                <div class="role-item ${roleClass}">
                                                    <div class="role-name">${role.Name}</div>
                                                    <div class="role-details">[STATUS(${role.State})${portInfo}]</div>
                                                    ${role.IPAddresses ? `<div class="role-ip">${role.IPAddresses}</div>` : ''}
                                                </div>
                                            `;
                                        }).join('')
                                    }
                                </div>
                            </div>
                        `;
                    }).join('')}
                </div>
            </div>
        `;
    }).join('');
}

// --- UDZIAŁY SIECIOWE ---
function renderFileShares(data) {
    const searchBar = document.getElementById('tabSearchBar');
    searchBar.innerHTML = '<input type="text" class="tab-search-input" placeholder="Szukaj w udziałach..." onkeyup="filterServers()">';
    
    const grid = document.getElementById('serverGrid');
    const servers = data.FileServers || [];
    if (servers.length === 0) { grid.innerHTML = '<div class="loading">Brak danych o udzialach sieciowych</div>'; return; }

    grid.innerHTML = servers.map(server => `
        <div class="server-card ${server.Error ? 'error' : ''}" data-server="${server.ServerName}">
            <div class="server-name">${server.ServerName}<span class="dmz-group">${server.ShareCount || 0} udziałów</span></div>
            ${server.Error ? '<div class="error-message">' + server.Error + '</div>' : `
            <div class="section"><div class="infra-table"><table>
                <thead><tr><th>Nazwa udziału</th><th>Ścieżka</th><th>Stan</th></tr></thead>
                <tbody>${(server.Shares || []).map(share => `
                    <tr>
                        <td><strong>${share.ShareName}</strong></td>
                        <td class="path-cell">${share.SharePath}</td>
                        <td><span class="status-badge ${share.ShareState === 'Online' ? 'status-on' : 'status-off'}">${share.ShareState}</span></td>
                    </tr>`).join('')}
                </tbody>
            </table></div></div>`}
        </div>`).join('');
}

// --- INSTANCJE SQL ---
function renderSQLInstances(data) {
    const searchBar = document.getElementById('tabSearchBar');
    searchBar.innerHTML = '<input type="text" class="tab-search-input" placeholder="Szukaj w instancjach SQL..." onkeyup="filterServers()">';

    const grid = document.getElementById('serverGrid');
    grid.classList.add('sql-grid');
    const instances = data.Instances || [];
    if (instances.length === 0) { grid.innerHTML = '<div class="loading">Brak danych o instancjach SQL</div>'; return; }

    grid.innerHTML = instances.map(inst => {
        return `
        <div class="server-card ${inst.Error ? 'error' : ''}" data-server="${inst.ServerName}">
            <div class="server-name">${inst.ServerName}</div>
            ${inst.Error ? '<div class="error-message">' + inst.Error + '</div>' : `
            <div class="metrics-grid" style="margin-bottom:12px">
                <div class="metric"><div class="metric-label">Wersja SQL</div><div class="metric-value" style="font-size:0.85em">${inst.SQLVersion || 'N/A'}</div></div>
                <div class="metric"><div class="metric-label">Ilość baz</div><div class="metric-value">${inst.DatabaseCount || 0}</div></div>
            </div>
            <div class="section">
                <div class="section-title collapsible" onclick="toggleSection(this)">Bazy danych (${inst.DatabaseCount || 0})</div>
                <div class="collapsible-content"><div class="infra-table"><table>
                    <thead><tr><th>Baza</th><th>Compat.</th><th>Data (MB)</th><th>Log (MB)</th><th>Razem (MB)</th></tr></thead>
                    <tbody>${(inst.Databases || []).map(db => `
                        <tr>
                            <td><strong>${db.DatabaseName}</strong></td>
                            <td>${db.CompatibilityLevel || ''}</td>
                            <td>${db.DataFileSizeMB || 0}</td>
                            <td>${db.LogFileSizeMB || 0}</td>
                            <td><strong>${db.TotalSizeMB || 0}</strong></td>
                        </tr>`).join('')}
                    </tbody>
                </table></div></div>
            </div>`}
        </div>`;
    }).join('');
}

// --- KOLEJKI MQ ---
function renderMQQueues(data) {
    const searchBar = document.getElementById('tabSearchBar');
    searchBar.innerHTML = '<input type="text" class="tab-search-input" placeholder="Szukaj w kolejkach MQ..." onkeyup="filterServers()">';
    
    const grid = document.getElementById('serverGrid');
    const servers = data.Servers || [];
    if (servers.length === 0) { 
        grid.innerHTML = '<div class="loading">Brak danych o kolejkach MQ.<br><small>Upewnij się, że plik config_mq.json istnieje w katalogu danych.</small></div>'; 
        return; 
    }

    // Buduj płaską listę wszystkich kolejek z QManager i Serwer
    const allQueues = [];
    servers.forEach(server => {
        if (server.Error) {
            allQueues.push({
                serverName: server.ServerName,
                queueManager: 'N/A',
                queueName: 'ERROR',
                error: server.Error
            });
        } else {
            (server.QueueManagers || []).forEach(qm => {
                (qm.Queues || []).forEach(q => {
                    allQueues.push({
                        serverName: server.ServerName,
                        queueManager: qm.QueueManager,
                        queueName: q.QueueName,
                        status: qm.Status,
                        port: qm.Port || '',
                        currentDepth: q.CurrentDepth,
                        maxDepth: q.MaxDepth
                    });
                });
            });
        }
    });

    if (allQueues.length === 0) {
        grid.innerHTML = '<div class="loading">Brak kolejek do wyświetlenia</div>';
        return;
    }

    grid.innerHTML = `
        <div class="mq-container" data-server="MQ-All">
            <div class="mq-header">
                <span>Kolejki IBM MQ</span>
                <span class="mq-count">${allQueues.length} kolejek</span>
            </div>
            <div class="mq-table">
                <table>
                    <thead>
                        <tr>
                            <th>QManager</th>
                            <th>Status</th>
                            <th>Port</th>
                            <th>Kolejka</th>
                            <th>Serwer</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${allQueues.map(item => {
                            if (item.error) {
                                return `<tr class="row-error"><td colspan="5">${item.serverName}: ${item.error}</td></tr>`;
                            }
                            const statusClass = item.status === 'Running' ? 'status-on' : 'status-off';
                            return `
                                <tr>
                                    <td><strong>${item.queueManager}</strong></td>
                                    <td><span class="status-badge ${statusClass}">${item.status}</span></td>
                                    <td>${item.port}</td>
                                    <td>${item.queueName}</td>
                                    <td class="mq-server">${item.serverName}</td>
                                </tr>
                            `;
                        }).join('')}
                    </tbody>
                </table>
            </div>
        </div>
    `;
}

// --- PRZEŁĄCZENIA RÓL KLASTRÓW ---
function renderRoleSwitches(data) {
    const searchBar = document.getElementById('tabSearchBar');
    searchBar.innerHTML = '<input type="text" class="tab-search-input" placeholder="Szukaj w przełączeniach..." onkeyup="filterRoleSwitches()">';

    const grid = document.getElementById('serverGrid');
    const switches = data.Switches || [];

    if (switches.length === 0) {
        grid.innerHTML = '<div class="loading">Brak zdarzeń przełączeń ról w ostatnich ' + (data.DaysBack || 30) + ' dniach</div>';
        return;
    }

    // Sortowanie i filtrowanie
    let sortColumn = 'TimeCreated';
    let sortDirection = 'desc';

    grid.innerHTML = `
        <div class="role-switches-container" data-server="RoleSwitches-All">
            <div class="mq-header">
                <span>Historia przełączeń ról klastrów</span>
                <span class="mq-count">${switches.length} zdarzeń (ostatnie ${data.DaysBack || 30} dni)</span>
            </div>
            <div class="mq-table">
                <table id="roleSwitchesTable">
                    <thead>
                        <tr>
                            <th class="sortable" data-sort="TimeCreated" onclick="sortRoleSwitches('TimeCreated')">Data/Czas <span class="sort-indicator">▼</span></th>
                            <th class="sortable" data-sort="ClusterName" onclick="sortRoleSwitches('ClusterName')">Klaster</th>
                            <th class="sortable" data-sort="ClusterType" onclick="sortRoleSwitches('ClusterType')">Typ</th>
                            <th class="sortable" data-sort="EventType" onclick="sortRoleSwitches('EventType')">Zdarzenie</th>
                            <th class="sortable" data-sort="RoleName" onclick="sortRoleSwitches('RoleName')">Rola</th>
                            <th class="sortable" data-sort="SourceNode" onclick="sortRoleSwitches('SourceNode')">Z węzła</th>
                            <th class="sortable" data-sort="TargetNode" onclick="sortRoleSwitches('TargetNode')">Na węzeł</th>
                        </tr>
                    </thead>
                    <tbody id="roleSwitchesBody">
                        ${switches.map(sw => {
                            const eventClass = getEventTypeClass(sw.EventType);
                            return `
                                <tr class="${eventClass}">
                                    <td>${sw.TimeCreated || ''}</td>
                                    <td><strong>${sw.ClusterName || ''}</strong></td>
                                    <td><span class="cluster-type-badge">${sw.ClusterType || ''}</span></td>
                                    <td><span class="event-type-badge ${eventClass}">${sw.EventType || ''}</span></td>
                                    <td>${sw.RoleName || ''}</td>
                                    <td>${sw.SourceNode || '-'}</td>
                                    <td>${sw.TargetNode || '-'}</td>
                                </tr>
                            `;
                        }).join('')}
                    </tbody>
                </table>
            </div>
        </div>
    `;

    // Zapisz dane do późniejszego sortowania
    window.roleSwitchesData = switches;
    window.roleSwitchesSort = { column: 'TimeCreated', direction: 'desc' };
}

function getEventTypeClass(eventType) {
    if (!eventType) return '';
    const et = eventType.toLowerCase();
    if (et.includes('failed') || et.includes('offline')) return 'event-error';
    if (et.includes('started') || et.includes('moved')) return 'event-warning';
    if (et.includes('completed') || et.includes('online')) return 'event-success';
    return '';
}

function sortRoleSwitches(column) {
    if (!window.roleSwitchesData) return;

    if (window.roleSwitchesSort.column === column) {
        window.roleSwitchesSort.direction = window.roleSwitchesSort.direction === 'asc' ? 'desc' : 'asc';
    } else {
        window.roleSwitchesSort.column = column;
        window.roleSwitchesSort.direction = 'asc';
    }

    const sorted = [...window.roleSwitchesData].sort((a, b) => {
        let valA = a[column] || '';
        let valB = b[column] || '';

        if (column === 'TimeCreated') {
            valA = new Date(valA);
            valB = new Date(valB);
        } else {
            valA = valA.toString().toLowerCase();
            valB = valB.toString().toLowerCase();
        }

        let result = 0;
        if (valA < valB) result = -1;
        if (valA > valB) result = 1;
        return window.roleSwitchesSort.direction === 'asc' ? result : -result;
    });

    const tbody = document.getElementById('roleSwitchesBody');
    if (!tbody) return;

    tbody.innerHTML = sorted.map(sw => {
        const eventClass = getEventTypeClass(sw.EventType);
        return `
            <tr class="${eventClass}">
                <td>${sw.TimeCreated || ''}</td>
                <td><strong>${sw.ClusterName || ''}</strong></td>
                <td><span class="cluster-type-badge">${sw.ClusterType || ''}</span></td>
                <td><span class="event-type-badge ${eventClass}">${sw.EventType || ''}</span></td>
                <td>${sw.RoleName || ''}</td>
                <td>${sw.SourceNode || '-'}</td>
                <td>${sw.TargetNode || '-'}</td>
            </tr>
        `;
    }).join('');

    // Aktualizuj wskaźniki sortowania
    document.querySelectorAll('#roleSwitchesTable th.sortable').forEach(th => {
        const indicator = th.querySelector('.sort-indicator');
        if (indicator) {
            if (th.dataset.sort === column) {
                indicator.textContent = window.roleSwitchesSort.direction === 'asc' ? '▲' : '▼';
            } else {
                indicator.textContent = '';
            }
        }
    });
}

function filterRoleSwitches() {
    const searchInput = document.querySelector('#tabSearchBar .tab-search-input');
    if (!searchInput) return;

    const search = searchInput.value.toLowerCase().trim();
    const rows = document.querySelectorAll('#roleSwitchesBody tr');

    rows.forEach(row => {
        const text = row.textContent.toLowerCase();
        if (!search || text.includes(search)) {
            row.style.display = '';
            if (search) {
                row.classList.add('highlight-row');
            } else {
                row.classList.remove('highlight-row');
            }
        } else {
            row.style.display = 'none';
            row.classList.remove('highlight-row');
        }
    });
}

// =============================================================================
// REFRESH / AUTO-UPDATE
// =============================================================================

async function refreshData() {
    // Dla zakładki logów - nie ma auto-odświeżania
    if (isLogsTab(currentGroup)) {
        return;
    }

    // Dla zakładek infra - po prostu przeładuj dane
    if (isInfraTab(currentGroup)) {
        const modal = document.getElementById('refreshModal');
        modal.classList.add('show');
        modal.querySelector('.modal-text').textContent = 'Odswiezanie danych...';
        await loadData();
        setTimeout(() => modal.classList.remove('show'), 500);
        return;
    }

    const modal = document.getElementById('refreshModal');
    const modalText = modal.querySelector('.modal-text');
    modal.classList.add('show');
    modalText.textContent = 'Sprawdzanie statusu taska...';

    const oldUpdate = serverData?.LastUpdate;

    try {
        const statusResponse = await fetch('api.aspx?action=taskstatus&t=' + Date.now());
        const statusResult = await statusResponse.json();

        if (statusResult.status === 'error') {
            modalText.textContent = 'Blad: ' + statusResult.message;
            if (statusResult.debug) console.error('Debug:', statusResult.debug);
            setTimeout(() => modal.classList.remove('show'), 5000);
            return;
        }

        const taskState = statusResult.taskState;

        if (taskState === 'Running') {
            modalText.textContent = 'Update juz trwa - czekam na zakonczenie...';
            waitForUpdate(oldUpdate, modal, modalText, true);
            return;
        }

        if (taskState === 'Ready') {
            modalText.textContent = 'Uruchamianie taska...';
            const refreshResponse = await fetch('api.aspx?action=refresh&t=' + Date.now());
            const refreshResult = await refreshResponse.json();

            if (refreshResult.status === 'error') {
                modalText.textContent = 'Blad: ' + refreshResult.message;
                if (refreshResult.debug) console.error('Debug:', refreshResult.debug);
                setTimeout(() => modal.classList.remove('show'), 5000);
                return;
            }

            if (refreshResult.status === 'started') {
                modalText.textContent = 'Task uruchomiony - czekam na dane...';
                waitForUpdate(oldUpdate, modal, modalText, false);
                return;
            }

            if (refreshResult.status === 'blocked') {
                modalText.textContent = 'Task nie jest gotowy: ' + refreshResult.taskState;
                setTimeout(() => modal.classList.remove('show'), 5000);
                return;
            }
        }

        modalText.textContent = 'Task nie jest gotowy (status: ' + taskState + ')';
        setTimeout(() => modal.classList.remove('show'), 5000);
    } catch (error) {
        modalText.textContent = 'Blad: ' + error.message;
        setTimeout(() => modal.classList.remove('show'), 5000);
    }
}

function waitForUpdate(oldUpdate, modal, modalText, wasRunning) {
    let attempts = 0;
    const maxAttempts = 120;

    const checkUpdate = async () => {
        attempts++;
        modalText.textContent = (wasRunning
            ? 'Update w trakcie - czekam... ('
            : 'Odswiezanie danych... (') + attempts + 's)';

        try {
            const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
            const data = await response.json();

            if (data.LastUpdate && data.LastUpdate !== oldUpdate) {
                location.reload();
                return;
            }
        } catch (e) {}

        if (attempts < maxAttempts) {
            setTimeout(checkUpdate, 1000);
        } else {
            modalText.textContent = 'Timeout - odswiezam strone...';
            setTimeout(() => location.reload(), 1000);
        }
    };

    setTimeout(checkUpdate, 2000);
}

// Auto-odświeżanie co 60s
async function checkForUpdates() {
    // Logi nie mają auto-odświeżania - każdy użytkownik sam pobiera dane
    if (isLogsTab(currentGroup)) return;

    try {
        if (isInfraTab(currentGroup)) {
            const response = await fetch('api.aspx?type=infra&group=' + currentGroup + '&t=' + Date.now());
            const text = await response.text();
            let data;
            try { data = JSON.parse(text); } catch (e) { return; }
            if (data.error) return;
            if (data.LastUpdate && infraData && data.LastUpdate !== infraData.LastUpdate) {
                infraData = data;
                updateInfraUI();
            } else if (!infraData) {
                infraData = data;
                updateInfraUI();
            }
        } else {
            const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
            const text = await response.text();
            let data;
            try { data = JSON.parse(text); } catch (e) { return; }
            if (data.error) return;
            if (data.LastUpdate && serverData && data.LastUpdate !== serverData.LastUpdate) {
                serverData = data;
                updateUI();
            } else if (!serverData) {
                serverData = data;
                updateUI();
            }
        }
    } catch (error) {
        // Cicha obsługa błędu
    }
}

// =============================================================================
// LOGS VIEWER MODULE
// Każdy użytkownik przeglądarki ma własną instancję stanu (logsData, currentServer, itd.)
// dzięki czemu wielu użytkowników może jednocześnie korzystać z przeglądarki logów
// bez wzajemnych interferencji.
// =============================================================================

const LogsViewer = (function() {
    // --- Stan per sesja przeglądarki (izolacja wielu użytkowników) ---
    let logsData = {};
    let currentServer = null;
    let currentSort = { column: 'TimeCreated', direction: 'desc' };
    let searchTerm = '';
    let logTypes = null;

    // --- Załaduj typy logów z konfiguracji ---
    async function loadLogTypes() {
        if (logTypes) return logTypes;
        try {
            const resp = await fetch('api.aspx?action=getLogTypes&t=' + Date.now());
            logTypes = await resp.json();
        } catch (e) {
            logTypes = [
                { name: 'Application', displayName: 'Application' },
                { name: 'System', displayName: 'System' }
            ];
        }
        return logTypes;
    }

    // --- Renderuj formularz i kontener wyników ---
    async function render() {
        const types = await loadLogTypes();
        const grid = document.getElementById('serverGrid');
        const searchBar = document.getElementById('tabSearchBar');
        searchBar.innerHTML = '';

        // Aktualizuj nagłówek statystyk
        document.getElementById('lastUpdate').textContent = '-';
        document.getElementById('duration').textContent = '-';
        document.getElementById('totalServers').textContent = '-';
        document.getElementById('successServers').textContent = '-';
        document.getElementById('failedServers').textContent = '-';
        document.getElementById('criticalServers').textContent = '-';

        grid.innerHTML = `
            <div class="logs-viewer">
                <div class="logs-form-container">
                    <div class="logs-title">Logi systemowe Windows Event Log</div>
                    <form id="logsQueryForm" class="logs-form">
                        <div class="logs-form-group">
                            <label for="logsServers">Serwery (oddzielone przecinkami):</label>
                            <input type="text" id="logsServers" placeholder="np. SERVER01, SERVER02" required>
                        </div>
                        <div class="logs-form-group">
                            <label for="logsLogType">Typ logów:</label>
                            <select id="logsLogType" required>
                                ${types.map((lt, i) => '<option value="' + lt.name + '"' + (i === 0 ? ' selected' : '') + '>' + lt.displayName + '</option>').join('')}
                            </select>
                        </div>
                        <div class="logs-form-group">
                            <label for="logsPeriod">Okres:</label>
                            <select id="logsPeriod" required>
                                <option value="10min">10 minut</option>
                                <option value="30min">30 minut</option>
                                <option value="1h" selected>1 godzina</option>
                                <option value="2h">2 godziny</option>
                                <option value="6h">6 godzin</option>
                                <option value="12h">12 godzin</option>
                                <option value="24h">24 godziny</option>
                            </select>
                        </div>
                        <button type="submit" id="logsSubmitBtn" class="logs-submit-btn">Pokaż logi</button>
                    </form>
                </div>

                <div id="logsLoader" class="logs-loader" style="display: none;">
                    <div class="spinner"></div>
                    <span>Pobieranie logów...</span>
                </div>

                <div id="logsError" class="logs-error" style="display: none;"></div>

                <div id="logsResults" style="display: none;">
                    <div id="logsServerTabs" class="logs-server-tabs"></div>
                    <div class="logs-search-container">
                        <input type="text" id="logsSearchInput" placeholder="Szukaj w logach...">
                        <span id="logsSearchCount"></span>
                    </div>
                    <div class="logs-table-container">
                        <table class="logs-table" id="logsTable">
                            <thead>
                                <tr>
                                    <th class="logs-sortable" data-logsort="TimeCreated">Data/Czas</th>
                                    <th class="logs-sortable" data-logsort="Level">Typ</th>
                                    <th class="logs-sortable" data-logsort="EventId">Kod zdarzenia</th>
                                    <th class="logs-sortable" data-logsort="Source">Źródło</th>
                                    <th class="logs-sortable" data-logsort="Message">Opis</th>
                                </tr>
                            </thead>
                            <tbody id="logsTableBody"></tbody>
                        </table>
                    </div>
                </div>
            </div>
        `;

        // Podłącz event handlery
        document.getElementById('logsQueryForm').addEventListener('submit', function(e) {
            e.preventDefault();
            submit();
        });

        document.getElementById('logsSearchInput').addEventListener('input', function(e) {
            searchTerm = e.target.value.trim().toLowerCase();
            if (currentServer) renderLogTable(currentServer);
        });

        document.querySelectorAll('.logs-sortable').forEach(function(th) {
            th.addEventListener('click', function() {
                handleSort(th.dataset.logsort);
            });
        });
    }

    // --- Wyślij formularz ---
    async function submit() {
        const servers = document.getElementById('logsServers').value.trim();
        const logType = document.getElementById('logsLogType').value;
        const period = document.getElementById('logsPeriod').value;

        if (!servers) {
            showError('Proszę podać nazwę serwera.');
            return;
        }

        showLoader(true);
        hideError();
        hideResults();

        try {
            const params = new URLSearchParams({
                action: 'getLogs',
                servers: servers,
                logType: logType,
                period: period,
                t: Date.now()
            });

            const response = await fetch('api.aspx?' + params.toString());

            if (!response.ok) {
                let errMsg = 'Błąd serwera (HTTP ' + response.status + ')';
                try {
                    const data = await response.json();
                    if (data.error) errMsg = data.error;
                } catch(e) {}
                throw new Error(errMsg);
            }

            const data = await response.json();
            showLoader(false);
            logsData = data;
            currentServer = null;
            searchTerm = '';
            const searchInput = document.getElementById('logsSearchInput');
            if (searchInput) searchInput.value = '';
            renderServerTabs(data);
            showResults();
        } catch (error) {
            showLoader(false);
            showError('Błąd pobierania logów: ' + error.message);
        }
    }

    // --- Renderuj zakładki serwerów ---
    function renderServerTabs(data) {
        const tabsContainer = document.getElementById('logsServerTabs');
        if (!tabsContainer) return;
        tabsContainer.innerHTML = '';

        const servers = Object.keys(data);
        if (servers.length === 0) {
            showError('Brak danych do wyświetlenia.');
            return;
        }

        servers.forEach(function(server, index) {
            const btn = document.createElement('button');
            btn.className = 'logs-server-tab';
            btn.type = 'button';

            const srvData = data[server];
            const logCount = srvData.success ? (Array.isArray(srvData.logs) ? srvData.logs.length : (srvData.logs ? 1 : 0)) : 0;

            btn.innerHTML = escapeHtml(server) + ' <span class="logs-count">(' + logCount + ')</span>';

            if (!srvData.success) {
                btn.classList.add('error');
                btn.title = srvData.error || 'Błąd pobierania logów';
            }

            btn.addEventListener('click', function() {
                selectServer(server, btn);
            });
            tabsContainer.appendChild(btn);

            if (index === 0) {
                selectServer(server, btn);
            }
        });
    }

    function selectServer(server, tabElement) {
        document.querySelectorAll('.logs-server-tab').forEach(function(t) { t.classList.remove('active'); });
        tabElement.classList.add('active');
        currentServer = server;
        renderLogTable(server);
    }

    // --- Renderuj tabelę logów ---
    function renderLogTable(server) {
        const tbody = document.getElementById('logsTableBody');
        if (!tbody) return;
        tbody.innerHTML = '';

        const srvData = logsData[server];
        if (!srvData) return;

        if (!srvData.success) {
            tbody.innerHTML = '<tr><td colspan="5" class="logs-no-data">Błąd: ' + escapeHtml(srvData.error) + '</td></tr>';
            updateSearchCount(0, 0);
            return;
        }

        let logs = srvData.logs;
        if (!logs || (Array.isArray(logs) && logs.length === 0)) {
            tbody.innerHTML = '<tr><td colspan="5" class="logs-no-data">Brak logów w wybranym okresie.</td></tr>';
            updateSearchCount(0, 0);
            return;
        }

        if (!Array.isArray(logs)) {
            logs = [logs];
        }

        // Normalizuj i sortuj
        logs = logs.map(normalizeLogEntry);
        logs = sortLogs(logs, currentSort.column, currentSort.direction);

        const totalCount = logs.length;

        // Filtruj wg wyszukiwania
        if (searchTerm) {
            logs = logs.filter(function(log) {
                return [log.Level, log.EventId.toString(), log.Source, log.Message]
                    .join(' ').toLowerCase().includes(searchTerm);
            });
        }

        updateSearchCount(logs.length, totalCount);

        if (logs.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="logs-no-data">Brak wyników dla "' + escapeHtml(searchTerm) + '"</td></tr>';
            return;
        }

        logs.forEach(function(log) {
            const tr = document.createElement('tr');
            tr.className = getLevelClass(log.Level);
            tr.innerHTML =
                '<td>' + formatDate(log.TimeCreated) + '</td>' +
                '<td>' + highlightText(escapeHtml(log.Level)) + '</td>' +
                '<td>' + highlightText(log.EventId.toString()) + '</td>' +
                '<td>' + highlightText(escapeHtml(log.Source)) + '</td>' +
                '<td class="logs-message-cell">' + highlightText(escapeHtml(truncateMessage(log.Message, 500))) + '</td>';
            tbody.appendChild(tr);
        });

        updateSortIndicators();
    }

    // --- Sortowanie ---
    function handleSort(column) {
        if (currentSort.column === column) {
            currentSort.direction = currentSort.direction === 'asc' ? 'desc' : 'asc';
        } else {
            currentSort.column = column;
            currentSort.direction = 'asc';
        }
        if (currentServer) renderLogTable(currentServer);
    }

    function sortLogs(logs, column, direction) {
        return logs.sort(function(a, b) {
            let valA = a[column];
            let valB = b[column];
            if (column === 'TimeCreated') {
                valA = new Date(valA);
                valB = new Date(valB);
            } else if (column === 'EventId') {
                valA = parseInt(valA) || 0;
                valB = parseInt(valB) || 0;
            } else {
                valA = (valA || '').toString().toLowerCase();
                valB = (valB || '').toString().toLowerCase();
            }
            let result = 0;
            if (valA < valB) result = -1;
            if (valA > valB) result = 1;
            return direction === 'asc' ? result : -result;
        });
    }

    function updateSortIndicators() {
        document.querySelectorAll('.logs-sortable').forEach(function(th) {
            th.classList.remove('logs-sort-asc', 'logs-sort-desc');
            if (th.dataset.logsort === currentSort.column) {
                th.classList.add('logs-sort-' + currentSort.direction);
            }
        });
    }

    // --- Pomocnicze ---
    function normalizeLogEntry(log) {
        return {
            TimeCreated: log.TimeCreated,
            Level: log.LevelDisplayName || log.Level || 'Unknown',
            EventId: log.Id || log.EventId || 0,
            Source: log.ProviderName || log.Source || 'Unknown',
            Message: log.Message || ''
        };
    }

    function getLevelClass(level) {
        if (!level) return '';
        const l = level.toLowerCase();
        if (l.includes('error')) return 'logs-level-error';
        if (l.includes('warning')) return 'logs-level-warning';
        if (l.includes('information')) return 'logs-level-info';
        if (l.includes('critical')) return 'logs-level-critical';
        return '';
    }

    function formatDate(dateString) {
        if (!dateString) return '';
        try {
            const date = new Date(dateString);
            return date.toLocaleString('pl-PL', {
                year: 'numeric', month: '2-digit', day: '2-digit',
                hour: '2-digit', minute: '2-digit', second: '2-digit'
            });
        } catch (e) {
            return dateString;
        }
    }

    function truncateMessage(msg, maxLen) {
        if (!msg) return '';
        if (msg.length <= maxLen) return msg;
        return msg.substring(0, maxLen) + '...';
    }

    function escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    function highlightText(text) {
        if (!searchTerm || !text) return text;
        const escaped = searchTerm.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const regex = new RegExp('(' + escaped + ')', 'gi');
        return text.replace(regex, '<span class="logs-highlight">$1</span>');
    }

    function updateSearchCount(filtered, total) {
        const el = document.getElementById('logsSearchCount');
        if (!el) return;
        if (searchTerm) {
            el.textContent = 'Znaleziono: ' + filtered + ' z ' + total;
        } else {
            el.textContent = total > 0 ? 'Wszystkich: ' + total : '';
        }
    }

    function showLoader(show) {
        const loader = document.getElementById('logsLoader');
        const btn = document.getElementById('logsSubmitBtn');
        if (loader) loader.style.display = show ? 'flex' : 'none';
        if (btn) btn.disabled = show;
    }

    function showResults() {
        const el = document.getElementById('logsResults');
        if (el) el.style.display = 'block';
    }

    function hideResults() {
        const el = document.getElementById('logsResults');
        if (el) el.style.display = 'none';
    }

    function showError(message) {
        const el = document.getElementById('logsError');
        if (el) {
            el.textContent = message;
            el.style.display = 'block';
        }
    }

    function hideError() {
        const el = document.getElementById('logsError');
        if (el) el.style.display = 'none';
    }

    // --- Publiczny interfejs ---
    return {
        render: render
    };
})();

// =============================================================================
// INIT
// =============================================================================
loadData();
setInterval(checkForUpdates, 60000);
