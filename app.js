// =============================================================================
// app.js - Server Health Monitor + Status Infrastruktury
// =============================================================================

let serverData = null;
let infraData = null;
let currentGroup = 'DCI';

// Zakładki infrastrukturalne
const infraTabs = {
    ClustersWindows: { renderer: renderClusters },
    UdzialySieciowe: { renderer: renderFileShares },
    InstancjeSQL:    { renderer: renderSQLInstances },
    KolejkiMQ:      { renderer: renderMQQueues }
};

function isInfraTab(group) {
    return group in infraTabs;
}

// =============================================================================
// LOADING DATA
// =============================================================================

async function loadData() {
    try {
        if (isInfraTab(currentGroup)) {
            const response = await fetch('api.aspx?type=infra&group=' + currentGroup + '&t=' + Date.now());
            infraData = await response.json();
            serverData = null;
            updateInfraUI();
        } else {
            const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
            serverData = await response.json();
            infraData = null;
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
    document.getElementById('tabSearchBar').innerHTML = '';

    // Resetuj filtr krytycznych
    criticalFilterActive = false;
    document.querySelector('.stat-card.warning').classList.remove('active');

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
        document.getElementById('totalServers').textContent = infraData.TotalClusters || 0;
        document.getElementById('successServers').textContent = infraData.OnlineCount || 0;
        document.getElementById('failedServers').textContent = infraData.FailedCount || 0;
        document.getElementById('criticalServers').textContent = '-';
    } else if (currentGroup === 'UdzialySieciowe') {
        const totalShares = (infraData.FileServers || []).reduce((sum, s) => sum + (s.ShareCount || 0), 0);
        document.getElementById('totalServers').textContent = infraData.TotalServers || 0;
        document.getElementById('successServers').textContent = totalShares;
        document.getElementById('failedServers').textContent = (infraData.FileServers || []).filter(s => s.Error).length;
        document.getElementById('criticalServers').textContent = '-';
    } else if (currentGroup === 'InstancjeSQL') {
        const totalDBs = (infraData.Instances || []).reduce((sum, s) => sum + (s.DatabaseCount || 0), 0);
        document.getElementById('totalServers').textContent = infraData.TotalInstances || 0;
        document.getElementById('successServers').textContent = totalDBs;
        document.getElementById('failedServers').textContent = (infraData.Instances || []).filter(s => s.Error).length;
        document.getElementById('criticalServers').textContent = '-';
    } else if (currentGroup === 'KolejkiMQ') {
        document.getElementById('totalServers').textContent = infraData.TotalServers || 0;
        const totalQM = (infraData.Servers || []).reduce((sum, s) => sum + (s.QueueManagers || []).length, 0);
        document.getElementById('successServers').textContent = totalQM;
        document.getElementById('failedServers').textContent = (infraData.Servers || []).filter(s => s.Error).length;
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
                                            const isMQ = role.Name && role.Name.match(/QM\d+/);
                                            const roleClass = isMQ ? 'role-mq' : (isOnline ? 'role-online' : 'role-offline');
                                            
                                            return `
                                                <div class="role-item ${roleClass}">
                                                    <div class="role-name">${role.Name}</div>
                                                    <div class="role-details">[STATUS(${role.State})]</div>
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
                    <thead><tr><th>Baza</th><th>Stan</th><th>Compat. Level</th></tr></thead>
                    <tbody>${(inst.Databases || []).map(db => `
                        <tr class="${db.State !== 'ONLINE' ? 'row-error' : ''}">
                            <td><strong>${db.DatabaseName}</strong></td>
                            <td><span class="status-badge ${db.State === 'ONLINE' ? 'status-on' : 'status-off'}">${db.State}</span></td>
                            <td>${db.CompatibilityLevel}</td>
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

// =============================================================================
// REFRESH / AUTO-UPDATE
// =============================================================================

async function refreshData() {
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
    try {
        if (isInfraTab(currentGroup)) {
            const response = await fetch('api.aspx?type=infra&group=' + currentGroup + '&t=' + Date.now());
            const data = await response.json();
            if (data.LastUpdate && infraData && data.LastUpdate !== infraData.LastUpdate) {
                infraData = data;
                updateInfraUI();
            } else if (!infraData) {
                infraData = data;
                updateInfraUI();
            }
        } else {
            const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
            const data = await response.json();
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
// INIT
// =============================================================================
loadData();
setInterval(checkForUpdates, 60000);
